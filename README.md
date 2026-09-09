# AI9 — Local GPU Manga Auto-Colorization for Firefox

**Designed by Antonio Garcia.**

Automatically colorizes black-and-white manga pages as you read them in Firefox,
using a **local GPU** (no cloud API, no per-page clicking, no upload step).
Built on top of [gilgamesh117/Manga-Colorizer](https://github.com/gilgamesh117/Manga-Colorizer)
(MIT licensed — see [LICENSE](LICENSE)), patched for:

- **Modern NVIDIA GPUs** (Blackwell / RTX 50-series and other `sm_120`+ cards)
  that the original `cu118`-era instructions don't support.
- **A Windows venv deployment** (no Docker required) with automatic
  restart-on-crash and restart-on-reboot.
- **A hash-based cache**, idle VRAM unloading, and a colorize-only-by-default
  mode (no forced 4x AI upscaling).
- **`<canvas>`-based readers**, not just `<img>` — the stock extension only
  ever looked at `<img src>`.

This was built and verified end-to-end on a Ryzen 7 7800X3D / RTX 5070 Ti
Windows box ("AI9"), targeting Crunchyroll Manga's web reader, but none of
the patches are Crunchyroll-specific — this works for any `<img>` or
`<canvas>`-based manga reader site.

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

Concurrency is 1 by default (`maxActiveFetches`) — one page colorizes at a
time, queued, so the GPU isn't hammered and stays available for other work.

## Prerequisites

- An NVIDIA GPU. This guide's exact versions were validated on an RTX 5070 Ti
  (`sm_120`, Blackwell) — **check your own GPU's compute capability and pick
  the matching PyTorch CUDA build** (see step 3). Don't blindly copy the
  `cu128` version below onto different hardware without checking.
- Windows 10/11 with the GPU's driver already installed (this guide does not
  touch the driver).
- Python 3.10+ (3.12 used here) and Git.
- Firefox (temporary unsigned extension loading — see Limitations).

## Setup

### 1. Inspect before you install anything

Don't assume driver/CUDA versions — check them:

```powershell
nvidia-smi
```

Note the driver version and the **CUDA Version** field in the top-right of
the output — that's the *maximum* CUDA toolkit version your driver supports,
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
this guide's copies directly — they're drop-in replacements with the same
file names, already patched).

```powershell
mkdir backend, models, cache, logs, extension
Copy-Item .\upstream\Backend\* .\backend\ -Recurse -Force
# then overwrite backend\app-stream.py, backend\upscalator.py, and
# backend\gpu_check.py with the patched versions from this guide's backend/
```

### 3. Download the model weights (not included in this repo — too large for git, and it's a third-party checkpoint)

- **Colorizer generator**: download from the link in the
  [upstream README](https://github.com/gilgamesh117/Manga-Colorizer#server-usage-instructions--local-hosting)
  (currently a Google Drive link) and save as `backend\networks\generator.zip`.
  Also copy it to `models\generator.zip` as your persisted, outside-of-code
  copy.
- **Upscaler**: `backend\networks\RealESRGAN_x4plus_anime_6B.pt` — already
  included when you clone the upstream repo (~17MB, checked into their repo).
- **Denoiser**: `backend\denoising\models\net_rgb.pth` — also already
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
| Older / no CUDA GPU | — | CPU build (slow) |

For an RTX 5070 Ti (this guide's hardware):

```powershell
.\venv\Scripts\python.exe -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
```

Verify it actually works — **`is_available() == True` is not sufficient
proof**; it can be true while still lacking compiled kernels for your
specific architecture. Run the included probe:

```powershell
.\venv\Scripts\python.exe backend\gpu_check.py
```

Expect output ending in `[PASS] GPU inference is functional on this device.`
with your GPU's `sm_XX` listed inside `compiled archs`. If it's not listed,
you have the wrong CUDA build for your hardware — go back to the table above.

### 5. First validation — one real image, before touching any browser

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
body — command-line argument passing chokes on large base64 strings, so
write the request to a file first) and confirm you get back a colorized,
non-corrupted, correctly-sized image. Grab a real test page from the model
author's own repo if you don't have one handy:
`https://raw.githubusercontent.com/qweasdd/manga-colorization-v2/master/figures/bw1.jpg`

Do not proceed past this point until this works.

### 6. Run it as a persistent service

No Docker was used for this deployment — there was nothing else running on
the target machine worth isolating from, and routing GPU access through
Docker Desktop's WSL2 layer on Windows adds real fragility for no benefit in
that situation. **If you're deploying onto a box that already runs other
Dockerized GPU workloads, containerizing this service instead is
reasonable** — just make sure whatever you use passes the GPU through
correctly (NVIDIA Container Toolkit) and doesn't touch other containers'
config.

For a bare-Windows venv deployment, use a Scheduled Task + a small
supervisor loop (Task Scheduler alone won't restart a script that's still
"running" after a crash inside an infinite loop, so the supervisor script
does the actual crash-restart):

```powershell
cd deploy
powershell -ExecutionPolicy Bypass -File register-task.ps1
```

This creates a task named `MangaColorizerAI9` that:
- starts `start_server.ps1` at logon (the GPU driver is WDDM, so this needs
  a real desktop session — it will not work as a headless SYSTEM service),
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

You'll get a self-signed certificate warning — that's expected (see
Limitations). Accept it once.

### 8. Install the Firefox extension

1. `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on** →
   select `extension/manifest.json`.
2. Open the extension popup, confirm the **API URL** field points at your
   server (`https://127.0.0.1:5000/` if Firefox runs on the same machine as
   the GPU, otherwise the LAN IP from step 7).
3. Click **Test** — accept the certificate warning once — confirm you see
   "Manga Colorizer is Up and Running!"
4. Your target site should already be in the **Manga Sites** box
   (`siteConfig.json` ships with `crunchyroll.com` plus the original
   upstream sites). If not, add it — this is a one-time step; the extension
   auto-injects into that domain from then on.

### 9. If your target site isn't behaving — probe its DOM first

Don't assume a site uses plain `<img>` tags. Open the reader, open DevTools
console (F12), paste and run `tools/crunchyroll_dom_probe.js` (works for any
site despite the name — it's generic). It reports whether pages are
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
| `--upscale_factor` | 4 | 2x is **not supported** by the bundled RealESRGAN checkpoint (its architecture is fixed-4x; the tile-placement math for scale=2 is broken upstream) — the server auto-promotes any 2x request to 4x rather than returning corrupted tiles |
| `--idle_unload_seconds` | 900 | frees GPU VRAM after this many idle seconds; reloads in well under a second on the next request |
| `--cache_root` | `<repo>/../cache` | cache is keyed by `sha256(original image bytes)[:32]` + a fingerprint of the processing options, so re-visiting a page with the same settings never re-runs the GPU, and different settings never collide |

**Extension** (`extension/popup.js` defaults): cache on, upscale off,
concurrency (`maxActiveFetches`) 1.

## Troubleshooting / gotchas actually hit while building this

- **`torch.load` fails with a `weights_only` UnpicklingError** — PyTorch
  2.6+ defaults `torch.load(weights_only=True)`. The colorizer and denoiser
  checkpoints are plain tensor state-dicts (fine either way), but the
  bundled `RealESRGAN_x4plus_anime_6B.pt` is a **fully pickled `nn.Module`**
  object, which the safe unpickler can't reconstruct at all — allowlisting
  the class isn't enough. `upscalator.py` in this guide explicitly passes
  `weights_only=False` for that one load, since it's a known, bundled,
  trusted-source file, not something fetched at request time.
- **Server logs seem to lag or a background daemon thread's prints never
  show up** — Python fully buffers stdout when it's piped to a file/log
  (unlike a real terminal), so infrequent `print()` calls can sit unflushed
  for a long time. Always launch with `python -u` (or `PYTHONUNBUFFERED=1`)
  for anything you're tailing a log on.
- **`/healthz` (or any "is the model loaded" diagnostic) flips between true
  and false with no obvious cause** — check whether an idle-unload
  background thread is running with a short timeout before assuming it's a
  bug. It's probably telling the truth.
- **Task Scheduler silently kills a long-running server after ~3 days** —
  the default `ExecutionTimeLimit` on a scheduled task is 3 days. Set it to
  `[TimeSpan]::Zero` explicitly (done in `register-task.ps1`).
- **`nvidia-smi --query-compute-apps` shows `N/A` for VRAM per process** —
  expected on Windows WDDM driver mode for consumer GPUs; it's not a bug.
  Measure your own process's actual usage from inside Python instead:
  `torch.cuda.memory_allocated()` / `memory_reserved()`.
- **A Firefox `<all_urls>` host permission is easy to reach for but not
  necessary** — declare the specific sites you need in `host_permissions`,
  and use `optional_host_permissions` + a runtime `permissions.request()`
  for anything added later, rather than granting blanket access at install
  time.

## Known limitations

- **Unsigned temporary extension**: stock Firefox will not persist a
  `Load Temporary Add-on` install across a browser restart. You'll need to
  reload it (`about:debugging` → Load Temporary Add-on) each time Firefox
  restarts, unless you get it signed by Mozilla or run Firefox
  Developer/ESR with `xpinstall.signatures.required` disabled (not done
  here — that's a real security trade-off, make that call yourself, not a
  default I'll silently flip).
- **Canvas-based readers**: a canvas can be repainted by the site's own JS
  (`drawImage`/`putImageData`) with **zero DOM mutation trace** — there is
  no browser event for "this canvas's pixels changed". `contentScript.js`
  falls back to a narrow, low-frequency (1.5s) content-fingerprint poll,
  but *only* on pages that actually contain a qualifying canvas — it never
  runs at all on `<img>`-based sites. This is a deliberate, disclosed
  exception to "prefer event-driven detection", not an oversight.
- **Self-signed certificate**: browsers will show a one-time trust warning
  per origin. Preserved as-is from upstream rather than standing up a real
  CA for a LAN-only service.
- **Site-specific title/chapter selectors** in `siteConfig.json` are
  best-effort for any site you haven't personally probed with
  `tools/crunchyroll_dom_probe.js` — this only affects cache folder naming
  though, not correctness (caching is keyed by image content hash
  regardless of whether title/chapter detection succeeds).

## Credits

- **Antonio Garcia** — designed this deployment: the GPU/CUDA compatibility
  work, the Windows venv + Scheduled Task service architecture, the caching
  and idle-VRAM design, and the Firefox extension patches (canvas support,
  least-privilege permissions, SPA detection) described in this guide.
- [gilgamesh117/Manga-Colorizer](https://github.com/gilgamesh117/Manga-Colorizer) —
  base project this guide patches (MIT license, see [LICENSE](LICENSE)).
- [qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2) —
  colorizer model/weights.
- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) — upscaler model.
