"""Post-processing color adjustment layer, applied after the GAN colorizer
(and after upscale/resize) so the model itself never needs retraining.

All operations are pointwise/global (contrast curves, HSV saturation/hue,
channel balance) -- none of them blur or geometrically distort pixels, so
line art stays sharp. Near-white and near-black regions (speech bubble
backgrounds, ink text) are naturally the most resistant to these ops: they
already sit at ~0 saturation, so saturation/hue-band operations are close to
a no-op there, and highlight softening is defined so pure white (1.0) always
maps back to exactly 1.0 -- see _highlight_softness.

All 11 parameters default to their identity value, so `apply_adjustments`
with no/default input is a guaranteed no-op (fast-pathed via `is_identity`,
bit-identical to the pre-adjustment pipeline output).
"""
import cv2
import numpy as np

DEFAULT_ADJUSTMENTS = {
    'saturation': 1.0,
    'contrast': 1.0,
    'brightness': 0.0,
    'gamma': 1.0,
    'warmth': 0.0,
    'hueShift': 0.0,
    'shadowTintStrength': 0.0,
    'magentaReduction': 0.0,
    'skinToneWarmth': 0.0,
    'blackLevel': 0.0,
    'highlightSoftness': 0.0,
}

# (min, max) clamps -- generous enough to be useful, tight enough that no
# combination can wreck line art / bubble legibility.
_RANGES = {
    'saturation': (0.0, 2.0),
    'contrast': (0.5, 1.8),
    'brightness': (-0.3, 0.3),
    'gamma': (0.5, 2.2),
    'warmth': (-1.0, 1.0),
    'hueShift': (-30.0, 30.0),
    'shadowTintStrength': (0.0, 1.0),
    'magentaReduction': (0.0, 1.0),
    'skinToneWarmth': (-1.0, 1.0),
    'blackLevel': (-0.2, 0.2),
    'highlightSoftness': (0.0, 1.0),
}

_MAGENTA_HUE = 300.0 / 360.0   # purple/magenta
_MAGENTA_WIDTH = 0.09
_SKIN_HUE = 28.0 / 360.0       # orange/flesh
_SKIN_WIDTH = 0.07


def normalize_adjustments(raw):
    """Merge caller-supplied values over the defaults and clamp to safe
    ranges. Missing/invalid keys silently fall back to their default --
    this is what makes "no adjustments sent" == current/original behavior."""
    out = dict(DEFAULT_ADJUSTMENTS)
    if raw:
        for key, (lo, hi) in _RANGES.items():
            if key in raw and raw[key] is not None:
                try:
                    out[key] = float(min(hi, max(lo, float(raw[key]))))
                except (TypeError, ValueError):
                    pass
    return out


def is_identity(adj):
    return all(adj[k] == DEFAULT_ADJUSTMENTS[k] for k in DEFAULT_ADJUSTMENTS)


def fingerprint(adj):
    """Short, deterministic, filename-safe cache key component."""
    return '-'.join(f'{k[:2]}{adj[k]:.2f}' for k in sorted(DEFAULT_ADJUSTMENTS))


def _hue_distance(h, center):
    d = np.abs(h - center)
    return np.minimum(d, 1.0 - d)  # wrap-around distance on the hue circle


def _black_level(img, amount):
    if amount == 0:
        return img
    if amount > 0:  # deepen/crush shadows
        return np.clip((img - amount) / max(1e-6, 1 - amount), 0, 1)
    lift = -amount  # lift/wash out shadows
    return img * (1 - lift) + lift


def _highlight_softness(img, amount, threshold=0.82):
    if amount <= 0:
        return img
    span = max(1e-6, 1 - threshold)
    over = np.clip(img - threshold, 0, span) / span
    compressed = np.power(over, 1 + amount * 2)  # soft-knee; over=1 (pure white) always -> 1
    return np.where(img > threshold, threshold + compressed * span, img)


def apply_adjustments(image_uint8, raw_adjustments):
    """image_uint8: HxWx3 RGB uint8 array. Returns a new HxWx3 uint8 array."""
    adj = normalize_adjustments(raw_adjustments)
    if is_identity(adj):
        return image_uint8

    img = image_uint8.astype(np.float32) / 255.0

    # Tone curve (RGB space)
    img = _black_level(img, adj['blackLevel'])
    if adj['gamma'] != 1.0:
        img = np.power(np.clip(img, 0, 1), 1.0 / adj['gamma'])
    if adj['brightness'] != 0:
        img = img + adj['brightness']
    if adj['contrast'] != 1.0:
        img = (img - 0.5) * adj['contrast'] + 0.5
    img = np.clip(img, 0, 1)

    # Warmth: direct R/B channel balance (white-balance style), not hue-based
    if adj['warmth'] != 0:
        img = img.copy()
        img[..., 0] = img[..., 0] * (1 + 0.18 * adj['warmth'])
        img[..., 2] = img[..., 2] * (1 - 0.18 * adj['warmth'])
        img = np.clip(img, 0, 1)

    # HSV-space adjustments. cv2's conversion is ~25-150x faster than
    # matplotlib.colors' pure-numpy version on a full-page image (measured:
    # ~480ms vs ~15ms round-trip on a 1874x1218 page) -- the difference
    # between "instant" and "sluggish" when switching presets, so it's
    # worth the (already-a-dependency) cv2 call over the more obvious
    # matplotlib helper. cv2 float HSV is H in [0,360], S/V in [0,1]; h is
    # normalized to [0,1] here to match this module's hue-fraction constants.
    hsv = cv2.cvtColor(np.ascontiguousarray(img, dtype=np.float32), cv2.COLOR_RGB2HSV)
    h, s, v = hsv[..., 0] / 360.0, hsv[..., 1], hsv[..., 2]

    if adj['hueShift'] != 0:
        h = (h + adj['hueShift'] / 360.0) % 1.0

    if adj['saturation'] != 1.0:
        s = np.clip(s * adj['saturation'], 0, 1)

    if adj['magentaReduction'] > 0:
        dist = _hue_distance(h, _MAGENTA_HUE)
        hue_weight = np.exp(-(dist / _MAGENTA_WIDTH) ** 2)
        shadow_weight = (1 - v) ** 1.5  # the complaint is specifically shadows
        s = np.clip(s * (1 - adj['magentaReduction'] * hue_weight * shadow_weight), 0, 1)

    if adj['skinToneWarmth'] != 0:
        dist = _hue_distance(h, _SKIN_HUE)
        weight = np.exp(-(dist / _SKIN_WIDTH) ** 2)
        s = np.clip(s * (1 + adj['skinToneWarmth'] * weight * 0.6), 0, 1)

    if adj['shadowTintStrength'] > 0:
        shadow_weight = (1 - v) ** 1.5
        s = np.clip(s * (1 - adj['shadowTintStrength'] * shadow_weight), 0, 1)

    hsv_out = np.stack([(h % 1.0) * 360.0, np.clip(s, 0, 1), np.clip(v, 0, 1)], axis=-1).astype(np.float32)
    img = cv2.cvtColor(hsv_out, cv2.COLOR_HSV2RGB)

    img = _highlight_softness(img, adj['highlightSoftness'])
    img = np.clip(img, 0, 1)

    return (img * 255.0).round().astype(np.uint8)
