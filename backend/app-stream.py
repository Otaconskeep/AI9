import argparse
import base64
import io
import json
import random
import threading
import time
import urllib.error
import urllib.request
import os
import gc
import hashlib
from pathlib import Path

import cv2
import PIL.Image
import numpy as np
from flask import Flask, request, jsonify, abort
from flask_cors import CORS

from denoisator import MangaDenoiser
from colorizator import MangaColorizator
from upscalator import MangaUpscaler
from utils.utils import distance_from_grayscale, generate_random_id, \
    image_to_base64, load_image_as_base64, save_image, sanitize_string, clear_torch_cache


app = Flask(__name__)
CORS(app, resources={r"/*": {"origins": "*"}})


@app.route('/')
def index():
    return 'Manga Colorizer is Up and Running!'


@app.route('/healthz')
def healthz():
    return jsonify({
        'status': 'up',
        'gpuLoaded': colorizer is not None,
        'device': config.device if config else None,
    })


@app.route('/colorize-image-data', methods=['POST'])
def colorize_image_data():
    rid = generate_random_id()
    note_activity()

    try:
        req_json = request.get_json()
        img_name = req_json.get('imgName', f'Image-{rid}')
        img_url = req_json.get('imgURL', '')
        img_data = req_json.get('imgData')
        img_width = req_json.get('imgWidth', -1)
        img_height = req_json.get('imgHeight', -1)
        colorize = req_json.get('colorize', config.colorize)
        upscale = req_json.get('upscale', config.upscale)
        denoise = req_json.get('denoise', config.denoise)
        denoise_sigma = req_json.get('denoiseSigma', config.denoise_sigma)
        upscale_factor = req_json.get('upscaleFactor', config.upscale_factor)
        cache = req_json.get('cache', False)
        manga_title = req_json.get('mangaTitle', '')
        manga_chapter = req_json.get('mangaChapter', '')

        if denoise_sigma < 0:
            print(f'[-] [{rid}] Denoiser sigma ({denoise_sigma}) cannot be negative, using default')
            denoise_sigma = config.denoise_sigma

        if upscale_factor not in [2, 4]:
            print(f'[-] [{rid}] Upscale factor ({upscale_factor}) must be 2 or 4, using default')
            upscale_factor = config.upscale_factor
        if upscale_factor == 2:
            # The bundled RealESRGAN checkpoint is a fixed 4x architecture; the
            # tiled x2 code path in utils.tile_process is known-broken (mismatched
            # tile placement math). Serve the correct 4x result instead of a
            # corrupted image rather than silently producing bad output.
            print(f'[-] [{rid}] upscaleFactor=2 is unsupported by this checkpoint, using 4')
            upscale_factor = 4

        ensure_components_loaded(rid)

        if img_data:
            img_metadata, img_data64 = img_data.split(',', 1)
            orig_image_binary = base64.decodebytes(bytes(img_data64, encoding='utf-8'))
        elif img_url:  # Could not find imgData, look for imgURL instead
            orig_image_binary = retrieve_image_binary(rid, request, img_url)
        else:
            msg = 'Neither imgData nor imgURL found in the request'
            print(f'[-] [{rid}] {msg}')
            return jsonify({'msg': f'Image: {img_name}, Error: {msg}'})

        content_hash = hashlib.sha256(orig_image_binary).hexdigest()[:32]

        if cache:
            cached_image = load_from_cache(manga_title, manga_chapter, content_hash,
                                            colorize, upscale, denoise, denoise_sigma, upscale_factor)
            if cached_image:
                print(f'[+] [{rid}] Cache hit ({content_hash[:12]}...), skipping GPU work')
                return jsonify({'colorImgData': cached_image, 'cached': True})

        imgio = io.BytesIO(orig_image_binary)
        image = PIL.Image.open(imgio)
        image = np.array(image.convert('RGB'))
        orig_h, orig_w = image.shape[:2]

        if not img_data:
            coloredness = distance_from_grayscale(PIL.Image.fromarray(image))
            print(f'[+] [{rid}] Image distance from grayscale: {coloredness}')
            if coloredness > 1:
                print(f'[+] [{rid}] Image already colored: {coloredness}')
                return jsonify({'msg': f'Image: {img_name}, Already colored: {coloredness} > 1'})

        print(f'[+] [{rid}] Requested image: {img_name}, Width: {img_width}, Height: {img_height}, hash={content_hash[:12]}')
        print(f'[+] [{rid}] Colorize: {colorize}, Upscale: {upscale}{f"(x{upscale_factor})" if upscale else ""}, Denoise: {denoise}')

        with gpu_lock:
            note_activity()
            if denoise:
                print(f'[*] [{rid}] Denoising image...')
                image = denoise_image(rid, image, denoiser, denoise_sigma)

            if colorize:
                print(f'[*] [{rid}] Colorizing image...')
                image = colorize_image(rid, image, colorizer, config.colorized_image_size)

            if upscale:
                print(f'[*] [{rid}] Upscaling image...')
                image = upscale_image(rid, image, upscaler, upscale_factor)
            elif (image.shape[0], image.shape[1]) != (orig_h, orig_w):
                # No AI super-resolution requested: restore the page's original
                # pixel dimensions with a plain, non-generative resize so text
                # stays readable instead of shipping the model's fixed internal
                # generation size (~576px wide).
                t0 = time.time()
                image = cv2.resize(image, (orig_w, orig_h), interpolation=cv2.INTER_LANCZOS4)
                print(f'[+] [{rid}] Resized (no upscale) {content_hash[:8]} to original {orig_w}x{orig_h} in {time.time()-t0:.2f}s')
            note_activity()

        if cache:
            try:
                save_to_cache(manga_title, manga_chapter, content_hash,
                               colorize, upscale, denoise, denoise_sigma, upscale_factor, image)
                print(f'[+] [{rid}] Image cached ({content_hash[:12]}...)')
            except Exception as te:
                print(f'[-] [{rid}] Error while caching: {te}')

        result_image_data64 = image_to_base64(image)
        return jsonify({'colorImgData': result_image_data64, 'cached': False})

    except RuntimeError as e:
        print(f'[!] [{rid}] Error: {e}')
        handle_cuda_error(e)

    response = jsonify({'msg': f'Image: {img_name}, Error: Unable to colorize'})
    return response


def handle_cuda_error(e):
    global colorizer, upscaler, denoiser

    if 'CUDA error: an illegal memory access was encountered' \
        in str(e) or 'CUDA out of memory' in str(e) or \
        'CUDA error: misaligned address' in str(e):
        print(f'[-] CUDA Error encountered, reinitializing...')
        colorizer = None
        upscaler = None
        denoiser = None
        clear_torch_cache()
        gc.collect()
        initialize_components()


# ---- Content-hash cache ----
# Cache identity is the sha256 of the original (pre-processing) image bytes,
# combined with a fingerprint of the processing options -- so the same page
# rendered with different colorize/upscale/denoise settings never collides,
# and a hit works even when manga_title/manga_chapter can't be detected
# (e.g. a site not yet in siteConfig.json).
def options_fingerprint(colorize, upscale, denoise, denoise_sigma, upscale_factor):
    return f"c{int(colorize)}-u{int(upscale)}x{upscale_factor if upscale else 0}-d{int(denoise)}s{denoise_sigma}"


def get_cache_dir(manga_title, manga_chapter):
    title_part = sanitize_string(manga_title.strip()) if manga_title else 'uncategorized'
    chapter_part = sanitize_string(manga_chapter.strip()) if manga_chapter else 'misc'
    return os.path.join(config.cache_root, title_part, chapter_part)


def get_cache_filename(manga_title, manga_chapter, content_hash, colorize, upscale, denoise, denoise_sigma, upscale_factor):
    chapter_dir = get_cache_dir(manga_title, manga_chapter)
    opts = options_fingerprint(colorize, upscale, denoise, denoise_sigma, upscale_factor)
    filename = f"{content_hash}_{opts}.webp"
    return os.path.join(chapter_dir, filename)


def save_to_cache(manga_title, manga_chapter, content_hash, colorize, upscale, denoise, denoise_sigma, upscale_factor, image):
    cache_filename = get_cache_filename(manga_title, manga_chapter, content_hash, colorize, upscale, denoise, denoise_sigma, upscale_factor)
    os.makedirs(os.path.dirname(cache_filename), exist_ok=True)
    save_image(image, cache_filename)


def load_from_cache(manga_title, manga_chapter, content_hash, colorize, upscale, denoise, denoise_sigma, upscale_factor):
    cache_filename = get_cache_filename(manga_title, manga_chapter, content_hash, colorize, upscale, denoise, denoise_sigma, upscale_factor)
    if os.path.exists(cache_filename):
        return load_image_as_base64(cache_filename)
    return None


def check_model_availability(rid, requested, available, name):
    if requested and not available:
        print(f'[-] [{rid}] Requested {name}, but model is not initialized, please run the server without --no-{name}')


def retrieve_image_binary(rid, original_request, url):
    user_agent = original_request.headers.get('User-Agent', '')
    referer = request.referrer if request.referrer else ''
    origin = request.origin if request.origin else ''

    referer = referer if referer else origin
    origin = origin if origin else referer

    headers = {
        'User-Agent': user_agent,
        'Referer': referer,
        'Origin': origin,
        'Accept': 'image/png;q=1.0,image/jpg;q=0.9,image/webp;q=0.7,image/*;q=0.5',
        'Accept-Language': 'en-US,en;q=0.5',
        'Accept-Encoding': 'identity'
    }

    print(f'[*] Retrieving image from url={url}')
    try:
        req = urllib.request.Request(url, headers=headers)
        return urllib.request.urlopen(req).read()
    except urllib.error.URLError as e:
        print(f'[!] [{rid}] URLError: {e.reason}')
        abort(500)
    except os.error as ex:
        print(f'[!] [{rid}] Retrieve error: {ex}')
    return False


def denoise_image(rid, image, denoiser, sigma):
    start_time = time.time()
    denoised_image = denoiser.denoise(image, sigma)
    elapsed_time = time.time() - start_time
    print(f'[+] [{rid}] Denoised image {[*image.shape]}->{[*denoised_image.shape]} in {elapsed_time:.2f} seconds.')
    return denoised_image


def colorize_image(rid, image, colorizer, size):
    start_time = time.time()
    colorizer.set_image((image.astype('float32') / 255), size)
    colorized_image = colorizer.colorize()
    elapsed_time = time.time() - start_time
    print(f'[+] [{rid}] Colorized image {[*image.shape]}->{[*colorized_image.shape]} in {elapsed_time:.2f} seconds.')
    return colorized_image


def upscale_image(rid, image, upscaler, factor):
    start_time = time.time()
    upscaled_image = upscaler.upscale((image.astype('float32') / 255), factor)
    elapsed_time = time.time() - start_time
    print(f'[+] [{rid}] Upscaled image (x{factor}) {[*image.shape]}->{[*upscaled_image.shape]} in {elapsed_time:.2f} seconds.')
    return upscaled_image


config = None
colorizer = None
upscaler = None
denoiser = None
gpu_lock = threading.Lock()
last_activity = time.time()
last_activity_lock = threading.Lock()


def note_activity():
    global last_activity
    with last_activity_lock:
        last_activity = time.time()


def initialize_components():
    global colorizer, upscaler, denoiser

    colorizer = MangaColorizator(config) if config.colorize else None
    upscaler = MangaUpscaler(config) if config.upscale_enabled else None
    denoiser = MangaDenoiser(config) if config.denoise else None
    print(f'[+] Components initialized')


def ensure_components_loaded(rid):
    with gpu_lock:
        if colorizer is None and config.colorize:
            print(f'[*] [{rid}] Models were idle-unloaded, reloading onto GPU...')
            initialize_components()
        note_activity()


def unload_idle_components():
    """Free GPU memory after config.idle_unload_seconds of no requests.

    AI9 also runs other GPU workloads; there's no reason to hold VRAM for a
    model that hasn't been used. Reload on the next request costs <1s.
    """
    global colorizer, upscaler, denoiser
    while True:
        time.sleep(30)
        if config.idle_unload_seconds <= 0:
            continue
        with last_activity_lock:
            idle_for = time.time() - last_activity
        if idle_for < config.idle_unload_seconds:
            continue
        with gpu_lock:
            with last_activity_lock:
                idle_for = time.time() - last_activity
            if idle_for < config.idle_unload_seconds:
                continue
            if colorizer is None and upscaler is None and denoiser is None:
                continue
            print(f'[+] Idle for {idle_for:.0f}s, unloading models from VRAM...')
            colorizer = None
            upscaler = None
            denoiser = None
            clear_torch_cache()
            gc.collect()
            print(f'[+] Models unloaded')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Run Manga Colorizer server')
    parser.add_argument('--device', choices=['cpu', 'cuda'], default='cuda', help='Device to use')
    parser.add_argument('--port', type=int, default=5000, help='Port to listen on')
    parser.add_argument('--host', default='0.0.0.0', help='Host/interface to bind')

    parser.add_argument('--colorizer_path', default='networks/generator.zip')
    parser.add_argument('--extractor_path', default='networks/extractor.pth')
    parser.add_argument('--upscaler_path', default='networks/RealESRGAN_x4plus_anime_6B.pt')
    parser.add_argument('--upscaler_type', choices=['ESRGAN', 'GigaGAN'], default='ESRGAN')

    parser.add_argument('--no-ssl', dest='ssl', action='store_false', default=True, help='Disable SSL context.')
    parser.add_argument('--upscale', dest='upscale', action='store_true', default=False,
                         help='Enable AI 4x super-resolution upscaling by default (off by default: '
                              'colorize-only + plain resize to original size, to avoid GAN artifacts on line art)')
    parser.add_argument('--no-colorize', dest='colorize', action='store_false', default=True,
                        help='Disable colorization')
    parser.add_argument('--no-denoise', dest='denoise', action='store_false', default=True, help='Disable denoiser')
    parser.add_argument('--upscale_factor', choices=[2, 4], default=4, type=int, help='Upscale by x2 or x4 (2 is unsupported by the bundled checkpoint, auto-promoted to 4)')
    parser.add_argument('--denoise_sigma', default=25, type=int, help='How much noise to expect from the image')
    parser.add_argument('--idle_unload_seconds', type=int, default=900,
                         help='Unload models from VRAM after this many idle seconds (0 disables)')
    parser.add_argument('--cache_root', default=None, help='Cache directory (default: ../cache relative to this file)')

    config = parser.parse_args()

    # The upscaler network object is still constructed at startup so the
    # first request that asks for upscale=true doesn't pay a cold-load
    # penalty; `upscale` only controls the default OUTCOME per request.
    config.upscale_enabled = True
    config.upscaler_tile_size = 256
    config.colorizer_tile_size = 0
    config.tile_pad = 8
    config.colorized_image_size = 576  # Width

    backend_dir = Path(__file__).resolve().parent
    config.cache_root = config.cache_root or str((backend_dir.parent / 'cache').resolve())
    os.makedirs(config.cache_root, exist_ok=True)
    print(f'[+] Cache root: {config.cache_root}')
    print(f'[+] Default upscale: {config.upscale} (per-request "upscale" flag can override)')
    print(f'[+] Idle VRAM unload after: {config.idle_unload_seconds}s')

    initialize_components()

    watchdog = threading.Thread(target=unload_idle_components, daemon=True)
    watchdog.start()

    if config.ssl:
        ssl_dir = backend_dir / 'ssl'
        context = (str(ssl_dir / 'server.crt'), str(ssl_dir / 'server.key'))
        app.run(host=config.host, port=config.port, ssl_context=context)
    else:
        app.run(host=config.host, port=config.port)
