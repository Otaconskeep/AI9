# AI9: Local GPU Manga Auto-Colorization for Firefox

**Designed by Antonio Garcia.**

Automatically colorizes black-and-white manga pages as you read them in Firefox,
using a **local GPU** (no cloud API, no per-page clicking, no upload step).
Built on top of [gilgamesh117/Manga-Colorizer](https://github.com/gilgamesh117/Manga-Colorizer)
(MIT licensed, see [LICENSE](LICENSE)), patched for:

- **Modern NVIDIA GPUs** (Blackwell / RTX 50-series and other `sm_120`+ cards)
  that the original `cu118`-era instructions don't support.
- **A Windows venv deployment** (no Docker required) with automatic
  restart-on-crash and restart-on-reboot.
- **A hash-based cache**, idle VRAM unloading, and a colorize-only-by-default
  mode (no forced 4x AI upscaling).
- **`<canvas>`-based readers**, not just `<img>`. The stock extension only
  ever looked at `<img src>`.
- **Adjustable color controls and preset filters** to tune saturation,
  contrast, brightness, gamma, warmth, hue, and specifically the model's
  tendency toward purple/magenta shadow casts and over-warm orange skin
  tones, as a fast post-processing step. See
  [Color adjustment controls](#color-adjustment-controls) below.

This was built and verified end-to-end on a Ryzen 7 7800X3D / RTX 5070 Ti
Windows box ("AI9"), targeting Crunchyroll Manga's web reader, but none of
the patches are Crunchyroll-specific. This works for any `<img>` or
`<canvas>`-based manga reader site.

## AI9 Manga Colorizer

Real local inference running through AI9. Black-and-white manga in, colorized page out.

This is a real capture of AI9 taking a black-and-white manga page through the local colorization workflow and producing the finished colored result.

![AI9 Manga Colorizer Demo](docs/assets/ai9-manga-colorizer-demo.gif)

**LOCAL GPU // HARDWARE-AWARE // SELF-HOSTED**

## Install (the easy way)

**Requirements: Windows 10/11, an NVIDIA RTX 30/40/50-series GPU with its
driver already installed. That's it, everything else gets installed for
you.**

1. Download this repo (green **Code** button → **Download ZIP**, then
   extract it anywhere) or `git clone` it.
2. Open the extracted `AI9` folder.
3. **Double-click `install_ai9.bat`.**

That's the whole install. A black window opens and does everything
automatically:

- installs Git and Python 3.12 if they're not already on your PC (via
  `winget`, no manual downloads),
- detects your specific NVIDIA GPU and picks the matching PyTorch/CUDA build
  for it (RTX 50 → `cu128`, RTX 40 → `cu126`/`cu121`, RTX 30 → `cu118`),
- downloads and verifies the AI model weights,
- runs a real GPU test (not just "is a GPU present", an actual inference
  pass) to prove colorization will work before it declares success,
- installs Firefox if it's missing,
- registers a Windows background task so the colorizer server starts
  automatically and restarts itself if it ever crashes,
- and finishes by printing the URL to open and the one remaining manual
  step (loading the Firefox extension, since browsers don't allow installers
  to do this part for you, see [step 8](#8-install-the-firefox-extension)).

It takes several minutes the first time (downloading Python packages and a
~200MB+ model file). **It's safe to just double-click it again** if
anything interrupts it, or to check for updates later. Every step skips
work that's already done and only fetches what's missing or changed.

If you'd rather run it from a terminal instead of double-clicking (or you're
scripting this onto multiple machines), open **Git Bash** in the folder and
run:

```bash
./install_ai9.sh
```

Both do the exact same thing. `install_ai9.bat` just finds/launches Git
Bash for you so there's nothing to open manually first.

**Optional overrides** (set these as normal Windows environment variables,
or `export` them before running `install_ai9.sh` from Git Bash, before
installing):

| Variable | Default | What it changes |
|---|---|---|
| `AI9_INSTALL_DIR` | `C:\opt\manga-colorizer` | Where AI9 gets installed |
| `AI9_INSTALL_FIREFOX` | `1` | Set to `0` to skip installing Firefox |
| `AI9_REGISTER_TASK` | `1` | Set to `0` to skip auto-registering the always-on background service |

Once it finishes, jump straight to [step 8](#8-install-the-firefox-extension)
below to load the Firefox extension. That's the only step a script can't do
for you (Firefox requires a human click for unsigned add-ons).

Want to know what's actually happening under the hood, tune something by
hand, or troubleshoot a failure? Everything below is the same install,
broken into manual steps, plus the full configuration/troubleshooting
reference.

## How it works

```
Firefox tab (manga site)
   │  contentScript.js watches the DOM (MutationObserver + History API hook)
   │  for new/changed <img> or <canvas> page elements
   ▼
POST https://<GPU host>:5000/colorize-image-data
   │  { imgData: <base64 PNG>, denoise, colorize, upscale, cache, ... }
   ▼
Flask server (app-stream.py) on the GPU machine
   │  denoise (FFDNet) → colorize (GAN) → [optional 4x upscale | plain resize]
   │  content-hash cache check/write
   ▼
Colorized image swapped into the page (new <img src> / redrawn <canvas>)
```

Concurrency is 1 by default (`maxActiveFetches`): one page colorizes at a
time, queued, so the GPU isn't hammered and stays available for other work.

## Manual setup (advanced / what the installer does step-by-step)

Use this section if you want to understand or debug the install, you're on
hardware the auto-installer doesn't recognize, or you just prefer doing it
by hand. If you already ran `install_ai9.bat`/`install_ai9.sh` successfully,
**you can skip straight to [step 8](#8-install-the-firefox-extension).**

### Prerequisites

- An NVIDIA GPU. This guide's exact versions were validated on an RTX 5070 Ti
  (`sm_120`, Blackwell). **Check your own GPU's compute capability and pick
  the matching PyTorch CUDA build** (see step 3). Don't blindly copy the
  `cu128` version below onto different hardware without checking.
- Windows 10/11 with the GPU's driver already installed (this guide does not
  touch the driver).
- Python 3.10+ (3.12 used here) and Git.
- Firefox (temporary unsigned extension loading, see Limitations).

### 1. Inspect before you install anything

Don't assume driver/CUDA versions, check them:

```powershell
nvidia-smi
```

Note the driver version and the **CUDA Version** field in the top-right of
the output. That's the *maximum* CUDA toolkit version your driver supports,
not the version you must use. What actually matters is whether a given
PyTorch build ships kernels for your GPU's **compute capability** (see step 4).

### 2. Get the code

```powershell
mkdir C:\opt\manga-colorizer
cd C:\opt\manga-colorizer
git clone https://github.com/gilgamesh117/Manga-Colorizer.git upstream
```

Copy this guide's `backend/` and `extension/` on top of
`upstream/Backend` and `upstream/Frontend-Firefox` respectively (or just use
this guide's copies directly, since they're drop-in replacements with the
same file names, already patched).

```powershell
mkdir backend, models, cache, logs, extension
Copy-Item .\upstream\Backend\* .\backend\ -Recurse -Force
# then overwrite backend\app-stream.py, backend\upscalator.py, and
# backend\gpu_check.py with the patched versions from this guide's backend/
```

### 3. Download the model weights (not included in this repo since it's too large for git, and it's a third-party checkpoint)

- **Colorizer generator**: download from the link in the
  [upstream README](https://github.com/gilgamesh117/Manga-Colorizer#server-usage-instructions--local-hosting)
  (currently a Google Drive link) and save as `backend\networks\generator.zip`.
  Also copy it to `models\generator.zip` as your persisted, outside-of-code
  copy.
- **Upscaler**: `backend\networks\RealESRGAN_x4plus_anime_6B.pt`, already
  included when you clone the upstream repo (~17MB, checked into their repo).
- **Denoiser**: `backend\denoising\models\net_rgb.pth`, also already
  included in the upstream clone (~3MB).

Verify the download actually worked (a bad/truncated Google Drive download
is the single most common failure mode here):

```powershell
python -c "import zipfile; zipfile.ZipFile('backend/networks/generator.zip').testzip(); print('OK, valid zip')"
```

### 4. Set up an isolated venv with the *correct* PyTorch build for your GPU

```powershell
python -m venv venv
.\venv\Scripts\python.exe -m pip install --upgrade pip
.\venv\Scripts\python.exe -m pip install -r backend\requirements.txt
.\venv\Scripts\python.exe -m pip install einops   # missing from upstream requirements.txt, needed by networks/aura_sr.py
```

Now the GPU-specific part. **Do not copy this command blindly.** Figure out
your GPU's compute capability first (`sm_XX`):

| GPU generation | Compute capability | PyTorch CUDA build to use |
|---|---|---|
| RTX 50-series (Blackwell) | sm_120 | `cu128` or newer |
| RTX 40-series (Ada) | sm_89 | `cu121`+ |
| RTX 30-series (Ampere) | sm_86 | `cu118`+ |
| Older / no CUDA GPU | N/A | CPU build (slow) |

For an RTX 5070 Ti (this guide's hardware):

```powershell
.\venv\Scripts\python.exe -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
```

Verify it actually works. **`is_available() == True` is not sufficient
proof**; it can be true while still lacking compiled kernels for your
specific architecture. Run the included probe:

```powershell
.\venv\Scripts\python.exe backend\gpu_check.py
```

Expect output ending in `[PASS] GPU inference is functional on this device.`
with your GPU's `sm_XX` listed inside `compiled archs`. If it's not listed,
you have the wrong CUDA build for your hardware. Go back to the table above.

### 5. First validation: one real image, before touching any browser

```powershell
cd backend
..\venv\Scripts\python.exe -u app-stream.py
```

In another terminal, health-check it:

```powershell
curl.exe -sk https://127.0.0.1:5000/
# expect: Manga Colorizer is Up and Running!
```

Then POST a real black-and-white manga image (base64-encoded in the JSON
body, since command-line argument passing chokes on large base64 strings, so
write the request to a file first) and confirm you get back a colorized,
non-corrupted, correctly-sized image. Grab a real test page from the model
author's own repo if you don't have one handy:
`https://raw.githubusercontent.com/qweasdd/manga-colorization-v2/master/figures/bw1.jpg`

Do not proceed past this point until this works.

### 6. Run it as a persistent service

No Docker was used for this deployment. There was nothing else running on
the target machine worth isolating from, and routing GPU access through
Docker Desktop's WSL2 layer on Windows adds real fragility for no benefit in
that situation. **If you're deploying onto a box that already runs other
Dockerized GPU workloads, containerizing this service instead is
reasonable**, just make sure whatever you use passes the GPU through
correctly (NVIDIA Container Toolkit) and doesn't touch other containers'
config.

For a bare-Windows venv deployment, use a Scheduled Task plus a small
supervisor loop (Task Scheduler alone won't restart a script that's still
"running" after a crash inside an infinite loop, so the supervisor script
does the actual crash-restart):

```powershell
cd deploy
powershell -ExecutionPolicy Bypass -File register-task.ps1
```

This creates a task named `MangaColorizerAI9` that:
- starts `start_server.ps1` at logon (the GPU driver is WDDM, so this needs
  a real desktop session; it will not work as a headless SYSTEM service),
- and whose supervisor loop restarts `app-stream.py` within 5 seconds of any
  crash, indefinitely.

Verify both halves actually work rather than trusting the task exists:

```powershell
# restart-on-reboot proxy test: stop and restart the task
Stop-ScheduledTask -TaskName MangaColorizerAI9  # (if you add this helper; or just log off/on)
Start-ScheduledTask -TaskName MangaColorizerAI9
Start-Sleep 8
curl.exe -sk https://127.0.0.1:5000/

# restart-on-crash test: kill the python process directly, wait ~10s, recheck
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Select ProcessId,CommandLine
Stop-Process -Id <pid> -Force
Start-Sleep 12
curl.exe -sk https://127.0.0.1:5000/   # should be back up
```

### 7. Find your reachable IP and confirm LAN access

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' }
```

Then from another device on the LAN (or the same machine via its LAN IP,
not `127.0.0.1`):

```
https://<that-ip>:5000/
```

You'll get a self-signed certificate warning. That's expected (see
Limitations). Accept it once.

### 8. Install the Firefox extension

1. `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on** →
   select `extension/manifest.json`.
2. Open the extension popup, confirm the **API URL** field points at your
   server (`https://127.0.0.1:5000/` if Firefox runs on the same machine as
   the GPU, otherwise the LAN IP from step 7).
3. Click **Test**, accept the certificate warning once, confirm you see
   "Manga Colorizer is Up and Running!"
4. Your target site should already be in the **Manga Sites** box
   (`siteConfig.json` ships with `crunchyroll.com` plus the original
   upstream sites). If not, add it. This is a one-time step; the extension
   auto-injects into that domain from then on.

### 9. If your target site isn't behaving, probe its DOM first

Don't assume a site uses plain `<img>` tags. Open the reader, open DevTools
console (F12), paste and run `tools/crunchyroll_dom_probe.js` (works for any
site despite the name, it's generic). It reports whether pages are
rendered as `<img>`, `<canvas>`, CSS background-image, or something else,
plus whether canvases are readable or CORS-tainted. Use that ground truth to
add/adjust an entry in `extension/siteConfig.json` if the generic detection
needs tuning for your specific site.

### 10. Read for real

Open a chapter, flip through at least 10 pages, confirm each one colorizes
automatically with no manual click and no indefinite blur/wait. Flip back to
an earlier page/chapter and confirm it comes back instantly from cache
(`cache/<title>/<chapter>/<hash>_<options>.webp` on the server).

## Configuration reference

**Server** (`backend/app-stream.py` CLI flags):

| Flag | Default | Notes |
|---|---|---|
| `--port` | 5000 | check it's free first: `Test-NetConnection -ComputerName localhost -Port 5000` or a quick Python socket bind test |
| `--host` | 0.0.0.0 | binds all interfaces so LAN clients can reach it |
| `--upscale` | off | AI 4x super-resolution; off by default. When off, output is still resized to the original page's exact dimensions via a plain (non-generative) `cv2.INTER_LANCZOS4` resize, not left at the model's fixed ~576px internal generation size |
| `--upscale_factor` | 4 | 2x is **not supported** by the bundled RealESRGAN checkpoint (its architecture is fixed-4x; the tile-placement math for scale=2 is broken upstream), so the server auto-promotes any 2x request to 4x rather than returning corrupted tiles |
| `--idle_unload_seconds` | 900 | frees GPU VRAM after this many idle seconds; reloads in well under a second on the next request |
| `--cache_root` | `<repo>/../cache` | cache is keyed by `sha256(original image bytes)[:32]` + a fingerprint of the processing options, so re-visiting a page with the same settings never re-runs the GPU, and different settings never collide |

**Extension** (`extension/popup.js` defaults): cache on, upscale off,
concurrency (`maxActiveFetches`) 1.

## Color adjustment controls

The GAN colorizer's raw output can run too strong in places: a purple/magenta
cast in shadows and over-warm orange skin tones being the two most common
complaints. Rather than retraining the model, `backend/color_adjust.py` is a
lightweight (numpy/OpenCV, no GPU) post-processing stage applied after
denoise → colorize → upscale/resize, controlled from the extension popup.

**Design**: 11 sliders (saturation, contrast, brightness, gamma, warmth, hue
shift, shadow tint reduction, magenta/purple reduction, skin tone warmth,
black level, highlight softness), all defaulting to a true no-op, so an
untouched request produces bit-identical output to the pre-adjustment
pipeline (`is_identity()` fast-path). Ten presets (`extension/presets.json`)
just set those same sliders to canned values; picking one doesn't lock you
out of then fine-tuning individual sliders afterward. The two operations
targeting the specific complaints (magenta reduction and skin tone warmth)
are hue-band-limited (Gaussian falloff around the magenta/orange hue, in
OpenCV HSV space) and, for magenta specifically, weighted toward dark pixels
(`(1-v)^1.5`), rather than a global saturation/hue shift, so the fix doesn't
bleed into unrelated colors. `_highlight_softness()` is defined so pure
white (1.0) always maps back to exactly 1.0, and every preset is verified to
keep bubble-white above 200/255 and bubble-black below 60/255 (see the
"Speech-bubble safety" check design in `color_adjust.py`'s docstring); line
art and text aren't blurred or geometrically touched by any of this, only
recolored.

**Presets** (full values in `extension/presets.json`):

| Preset | What it does |
|---|---|
| Default | No-op, current/original behavior |
| Neutral | Mild overall cleanup: slightly desaturated, slight purple/orange correction |
| Soft Anime | Lower contrast, softened highlights, gentler and less harsh |
| Warm | Pushes warmth and skin tone up (a stylistic choice, not a bug fix) |
| Cool | Pushes warmth down, slightly cooler hue |
| Night Scene | Deeper blacks, lower brightness, cooler, with strong magenta suppression (dark scenes are where the cast is worst) |
| Reduced Purple Cast | Isolated, strong fix: shadow tint reduction 0.5, magenta reduction 0.7, everything else neutral |
| Lower Contrast | Isolated contrast reduction (0.75) + highlight softening, everything else neutral |
| Vivid | Punchier: higher saturation and contrast, opposite of Soft Anime |
| Manga Safe / Text Safe | Near-neutral saturation, crisper linework contrast, strong highlight protection for bubble whites |

**Caching**: the two operations that used to be one cache tier are now two.
The "raw" tier caches the GPU model's output (denoise+colorize+upscale),
keyed by model options only. The "final" tier caches what's actually
returned to the client, keyed by model options *and* the active adjustment
values. Switching presets/sliders on a page you've already read reuses the
cached raw GPU output and only re-runs the cheap adjustment step (~450ms on
a full page, vs ~1.2s for a cold GPU run) instead of a full GPU re-run;
re-requesting the exact same (image, settings) combination is a ~30-50ms
cache hit either way. This is why `color_adjust.py` uses `cv2.cvtColor` for
HSV conversion rather than the more obvious `matplotlib.colors` helper:
measured ~25-150x faster on a full-page image (480ms vs ~15ms), which is the
difference between "instant" and "sluggish" when trying different presets.

**Persistence**: sliders and the active preset are saved to
`browser.storage.local` immediately on change (not gated behind the
"Colorize!" button), so they survive a Firefox restart the same way the
other settings do.

## Troubleshooting / gotchas actually hit while building this

- **Double-clicking `install_ai9.bat` flashes a window and closes, or SmartScreen
  warns about an unrecognized app**: this is a plain batch/bash script, not a
  signed binary, so Windows SmartScreen may flag it the first time; click
  **More info → Run anyway**. If it closes instantly with no message, right-click
  it → **Run as administrator is not required**, but do check that Git Bash
  (`C:\Program Files\Git\bin\bash.exe`) exists; if it doesn't, the `.bat` should
  install Git itself via `winget`. If `winget` also isn't available, install
  ["App Installer"](https://apps.microsoft.com/detail/9nblggh4nns1) from the
  Microsoft Store first, then rerun.
- **The installer fails partway through**: it's designed to be safe to just
  rerun (`install_ai9.bat` again, or `./install_ai9.sh`); every step checks
  what's already done (repo cloned, venv created, correct PyTorch installed,
  weights downloaded) and skips it, so a rerun only redoes the step that failed.
- **`torch.load` fails with a `weights_only` UnpicklingError**: PyTorch
  2.6+ defaults `torch.load(weights_only=True)`. The colorizer and denoiser
  checkpoints are plain tensor state-dicts (fine either way), but the
  bundled `RealESRGAN_x4plus_anime_6B.pt` is a **fully pickled `nn.Module`**
  object, which the safe unpickler can't reconstruct at all. Allowlisting
  the class isn't enough. `upscalator.py` in this guide explicitly passes
  `weights_only=False` for that one load, since it's a known, bundled,
  trusted-source file, not something fetched at request time.
- **Server logs seem to lag or a background daemon thread's prints never
  show up**: Python fully buffers stdout when it's piped to a file/log
  (unlike a real terminal), so infrequent `print()` calls can sit unflushed
  for a long time. Always launch with `python -u` (or `PYTHONUNBUFFERED=1`)
  for anything you're tailing a log on.
- **`/healthz` (or any "is the model loaded" diagnostic) flips between true
  and false with no obvious cause**: check whether an idle-unload
  background thread is running with a short timeout before assuming it's a
  bug. It's probably telling the truth.
- **Task Scheduler silently kills a long-running server after ~3 days**:
  the default `ExecutionTimeLimit` on a scheduled task is 3 days. Set it to
  `[TimeSpan]::Zero` explicitly (done in `register-task.ps1`).
- **`nvidia-smi --query-compute-apps` shows `N/A` for VRAM per process**:
  expected on Windows WDDM driver mode for consumer GPUs; it's not a bug.
  Measure your own process's actual usage from inside Python instead:
  `torch.cuda.memory_allocated()` / `memory_reserved()`.
- **A Firefox `<all_urls>` host permission is easy to reach for but not
  necessary**: declare the specific sites you need in `host_permissions`,
  and use `optional_host_permissions` + a runtime `permissions.request()`
  for anything added later, rather than granting blanket access at install
  time.
- **A new manga site injects fine but every image fails with `Colorized
  context error: SecurityError` in the console**: cross-origin canvas
  taint detection must check `exception.name === 'SecurityError'`, not
  `exception.message`. Chrome's message for this is `"Failed to execute
  'getImageData'..."`; Firefox's is `"The operation is insecure."` They
  never match, so message-string checks (the original upstream code did
  this, and it got copied into this guide's canvas-support path too before
  being caught) silently skip the `imgURL` server-side-fetch fallback on
  Firefox specifically, on every image sourced from a different origin than
  the page itself (a very common setup: CDN-hosted manga pages). Fixed in
  `contentScript.js`'s two `catch(eIsColor)` blocks.
- **A new site's manifest permissions are added but "Reload" in
  `about:debugging` doesn't pick them up**: for a temporary add-on,
  permission changes in particular can survive a `Reload` in a stale state.
  Remove it and use "Load Temporary Add-on" fresh instead when you've
  changed `host_permissions`/`web_accessible_resources`.
- **`web_accessible_resources` `matches` is a static manifest list. A
  runtime `permissions.request()` grant can't extend it.** If a
  non-secret bundled file (like `siteConfig.json`, just CSS selector
  strings, no user data) needs to be reachable from *any* dynamically-added
  site, its `matches` needs to be `["<all_urls>"]` up front; narrowing it to
  a fixed list breaks every site added later through the "Add site" flow,
  not just the one you're currently testing.

## Known limitations

- **Unsigned temporary extension**: stock Firefox will not persist a
  `Load Temporary Add-on` install across a browser restart. You'll need to
  reload it (`about:debugging` → Load Temporary Add-on) each time Firefox
  restarts, unless you get it signed by Mozilla or run Firefox
  Developer/ESR with `xpinstall.signatures.required` disabled (not done
  here; that's a real security trade-off, make that call yourself, not a
  default I'll silently flip).
- **Canvas-based readers**: a canvas can be repainted by the site's own JS
  (`drawImage`/`putImageData`) with **zero DOM mutation trace**. There is
  no browser event for "this canvas's pixels changed". `contentScript.js`
  falls back to a narrow, low-frequency (1.5s) content-fingerprint poll,
  but *only* on pages that actually contain a qualifying canvas. It never
  runs at all on `<img>`-based sites. This is a deliberate, disclosed
  exception to "prefer event-driven detection", not an oversight.
- **Self-signed certificate**: browsers will show a one-time trust warning
  per origin. Preserved as-is from upstream rather than standing up a real
  CA for a LAN-only service.
- **Site-specific title/chapter selectors** in `siteConfig.json` are
  best-effort for any site you haven't personally probed with
  `tools/crunchyroll_dom_probe.js`. This only affects cache folder naming
  though, not correctness (caching is keyed by image content hash
  regardless of whether title/chapter detection succeeds).

## Support

Hit a wall the [troubleshooting section](#troubleshooting--gotchas-actually-hit-while-building-this)
above doesn't cover, or just want to say it worked? Come by Discord:

### 💬 [discord.gg/cZDeqECzX](https://discord.gg/cZDeqECzX)

Post your GPU model, the exact error text, and whether it happened during
install or while reading. That's usually enough to diagnose it fast.

## About the Engineer

**Antonio G. Garcia ("Otaconskeep")** designs and ships local-first AI
infrastructure end to end, not just prompting a model, but the layer
underneath it: GPU/CUDA compatibility across NVIDIA generations, deployment
automation that survives reboots and crashes unattended, content-addressed
caching strategies, and browser-extension internals down to cross-browser
`DOMException` behavior. This repository is a worked example of that: real
GPU inference (not a cloud API call wearing a GPU's name), a two-tier cache
keyed by content hash *and* processing options, and a cross-browser bug
(`.name` vs `.message` on a `SecurityError`) that shipped in the original
upstream project undetected until it was root-caused and fixed here.

Available for consulting on local AI deployment, GPU/CUDA compatibility
work, and browser-extension engineering. Reach out in Discord above.

## Credits

- **Antonio Garcia** designed this deployment: the GPU/CUDA compatibility
  work, the Windows venv + Scheduled Task service architecture, the caching
  and idle-VRAM design, the Firefox extension patches (canvas support,
  least-privilege permissions, SPA detection), and the one-click
  `install_ai9.bat`/`install_ai9.sh` installer described in this guide.
- [gilgamesh117/Manga-Colorizer](https://github.com/gilgamesh117/Manga-Colorizer):
  base project this guide patches (MIT license, see [LICENSE](LICENSE)).
- [qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2):
  colorizer model/weights.
- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN): upscaler model.
