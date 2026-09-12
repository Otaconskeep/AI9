#!/usr/bin/env bash
set -Eeuo pipefail

BRAND="ANTONIO G. GARCIA // OTACONSKEEP"
PRODUCT="AI9 AUTOMATED INSTALLER"
TAGLINE="Built for the Keep."

# AI9 / Manga-Colorizer one-shot Windows installer
# Target shell: Git Bash on Windows 10/11
#
# What it does:
#   - Installs Python 3.12 if missing
#   - Installs/updates AI9 + upstream Manga-Colorizer source
#   - Builds the deployed backend/extension tree
#   - Detects RTX 30/40/50-series GPU
#   - Selects an appropriate PyTorch CUDA wheel
#   - Creates/reuses a venv and installs Python dependencies
#   - Downloads/verifies generator.zip if missing
#   - Runs AI9's real GPU kernel/cuDNN probe
#   - Registers/starts the Windows Scheduled Task
#   - Health-checks the backend
#
# Optional environment variables:
#   AI9_INSTALL_DIR=/c/opt/manga-colorizer
#   AI9_INSTALL_FIREFOX=1
#   AI9_REGISTER_TASK=1

AI9_REPO="https://github.com/Otaconskeep/AI9.git"
UPSTREAM_REPO="https://github.com/gilgamesh117/Manga-Colorizer.git"
GENERATOR_FILE_ID="1qmxUEKADkEM4iYLp1fpPLLKnfZ6tcF-t"

INSTALL_DIR="${AI9_INSTALL_DIR:-/c/opt/manga-colorizer}"
INSTALL_FIREFOX="${AI9_INSTALL_FIREFOX:-1}"
REGISTER_TASK="${AI9_REGISTER_TASK:-1}"

SOURCE_DIR="$INSTALL_DIR/.sources"
AI9_SRC="$SOURCE_DIR/AI9"
UPSTREAM_SRC="$SOURCE_DIR/Manga-Colorizer"
VENV_DIR="$INSTALL_DIR/venv"
VENV_PY="$VENV_DIR/Scripts/python.exe"


log()  { printf '\n\033[1;36m[AGG::AI9]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[AGG::OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AGG::WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[AGG::FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'printf "\n\033[1;31m[AGG::FAIL]\033[0m Installer stopped on line %s.\n" "$LINENO" >&2' ERR

is_windows_bash() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

printf '\033[1;35m'
cat <<'AGG_ASCII'
 __  __    _    _   _  ____    _
|  \/  |  / \  | \ | |/ ___|  / \
| |\/| | / _ \ |  \| | |  _  / _ \
| |  | |/ ___ \| |\  | |_| |/ ___ \
|_|  |_/_/   \_\_| \_|\____/_/   \_\

  ____ ___  _     ___  ____  ___ _______ ____
 / ___/ _ \| |   / _ \|  _ \|_ _|__  /| ____|
| |  | | | | |  | | | | |_) || |  / / |  _|
| |__| |_| | |__| |_| |  _ < | | / /_ | |___
 \____\___/|_____\___/|_| \_\___/____||_____|

========================================================
          O T A C O N S K E E P   A I 9
                 I N S T A L L E R
========================================================
                 ANTONIO G. GARCIA
               Built for the Keep.
========================================================
AGG_ASCII
printf '\033[0m\n'
printf '\033[1;36m%s\033[0m\n' "$BRAND"
printf '\033[0;37m%s — %s\033[0m\n\n' "$PRODUCT" "$TAGLINE"

is_windows_bash || die "This installer targets Windows 10/11 under Git Bash. Do not run it inside WSL."

command_exists() { command -v "$1" >/dev/null 2>&1; }

winpath() {
  if command_exists cygpath; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

version_ge() {
  # usage: version_ge 12.8 12.6
  awk -v A="$1" -v B="$2" '
    BEGIN {
      split(A,a,"."); split(B,b,".");
      am=a[1]+0; an=a[2]+0; bm=b[1]+0; bn=b[2]+0;
      exit !((am > bm) || (am == bm && an >= bn));
    }'
}

find_winget() {
  if command_exists winget.exe; then
    printf '%s\n' "winget.exe"
    return 0
  fi
  local candidate="/c/Users/${USERNAME:-}/AppData/Local/Microsoft/WindowsApps/winget.exe"
  [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  return 1
}

WINGET="$(find_winget || true)"

winget_install() {
  local package_id="$1"
  [[ -n "$WINGET" ]] || die "winget is unavailable. Install Microsoft's 'App Installer', reopen Git Bash, and rerun."
  "$WINGET" install \
    --id "$package_id" \
    -e \
    --source winget \
    --accept-package-agreements \
    --accept-source-agreements \
    --disable-interactivity
}

find_git() {
  if command_exists git; then
    command -v git
    return 0
  fi
  for p in \
    "/c/Program Files/Git/cmd/git.exe" \
    "/c/Program Files/Git/bin/git.exe" \
    "/c/Program Files (x86)/Git/cmd/git.exe"
  do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

log "OTACONSKEEP preflight: checking Git"
GIT="$(find_git || true)"
if [[ -z "$GIT" ]]; then
  log "Git is missing; installing it"
  winget_install "Git.Git"
  GIT="$(find_git || true)"
  [[ -n "$GIT" ]] || die "Git installed but is not visible yet. Reopen Git Bash and rerun this installer."
fi
ok "Git: $("$GIT" --version)"

python_is_usable() {
  local exe="$1"
  "$exe" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1
}

find_python() {
  local p
  for p in \
    "$(command -v python.exe 2>/dev/null || true)" \
    "$(command -v python 2>/dev/null || true)" \
    "/c/Users/${USERNAME:-}/AppData/Local/Programs/Python/Python312/python.exe" \
    "/c/Program Files/Python312/python.exe"
  do
    [[ -n "$p" && -x "$p" ]] || continue
    if python_is_usable "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

log "OTACONSKEEP preflight: checking Python"
PYTHON="$(find_python || true)"
if [[ -z "$PYTHON" ]]; then
  log "Python 3.10+ is missing; installing Python 3.12"
  winget_install "Python.Python.3.12"
  PYTHON="$(find_python || true)"
  [[ -n "$PYTHON" ]] || die "Python installed but could not be located. Reopen Git Bash and rerun."
fi
ok "Python: "$("$PYTHON" --version 2>&1)""

# Find nvidia-smi. We intentionally do NOT install a CUDA Toolkit here:
# PyTorch wheels bring their own CUDA runtime. The NVIDIA driver must exist.
find_nvidia_smi() {
  local p
  if command_exists nvidia-smi.exe; then command -v nvidia-smi.exe; return 0; fi
  if command_exists nvidia-smi; then command -v nvidia-smi; return 0; fi
  for p in \
    "/c/Windows/System32/nvidia-smi.exe" \
    "/c/Program Files/NVIDIA Corporation/NVSMI/nvidia-smi.exe"
  do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

log "Antonio G. Garcia hardware scan: identifying NVIDIA GPU and driver"
NVIDIA_SMI="$(find_nvidia_smi || true)"
[[ -n "$NVIDIA_SMI" ]] || die "nvidia-smi was not found. Install the NVIDIA GPU driver first, then rerun. A standalone CUDA Toolkit is not required."

GPU_NAME="$("$NVIDIA_SMI" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | tr -d '\r')"
[[ -n "$GPU_NAME" ]] || die "Could not identify the NVIDIA GPU with nvidia-smi."

CUDA_MAX="$("$NVIDIA_SMI" 2>/dev/null | sed -nE 's/.*CUDA Version: ([0-9]+\.[0-9]+).*/\1/p' | head -n1 | tr -d '\r')"
[[ -n "$CUDA_MAX" ]] || die "Could not read the driver's maximum CUDA version from nvidia-smi."

case "$GPU_NAME" in
  *"RTX 50"*)
    TORCH_FLAVOR="cu128"
    TORCH_CUDA="12.8"
    MIN_DRIVER_CUDA="12.8"
    GPU_FAMILY="RTX 50-series / Blackwell"
    ;;
  *"RTX 40"*)
    GPU_FAMILY="RTX 40-series / Ada"
    if version_ge "$CUDA_MAX" "12.6"; then
      TORCH_FLAVOR="cu126"
      TORCH_CUDA="12.6"
      MIN_DRIVER_CUDA="12.6"
    elif version_ge "$CUDA_MAX" "12.1"; then
      TORCH_FLAVOR="cu121"
      TORCH_CUDA="12.1"
      MIN_DRIVER_CUDA="12.1"
    else
      die "$GPU_NAME detected, but the driver only advertises CUDA $CUDA_MAX. Update the NVIDIA driver and rerun."
    fi
    ;;
  *"RTX 30"*)
    TORCH_FLAVOR="cu118"
    TORCH_CUDA="11.8"
    MIN_DRIVER_CUDA="11.8"
    GPU_FAMILY="RTX 30-series / Ampere"
    ;;
  *)
    die "Unsupported/unknown automatic GPU mapping: '$GPU_NAME'. This installer currently auto-selects PyTorch for RTX 30, 40, and 50 series."
    ;;
esac

version_ge "$CUDA_MAX" "$MIN_DRIVER_CUDA" || \
  die "$GPU_NAME needs at least the $TORCH_FLAVOR PyTorch runtime, but the installed driver reports CUDA $CUDA_MAX. Update the NVIDIA driver and rerun."

ok "GPU: $GPU_NAME"
ok "Family: $GPU_FAMILY"
ok "Driver supports CUDA up to: $CUDA_MAX"
ok "Selected PyTorch wheel: $TORCH_FLAVOR"

# Choose a writable install location. C:\opt keeps compatibility with the repo docs.
if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
  warn "Cannot write to $INSTALL_DIR; falling back to your user profile."
  INSTALL_DIR="$HOME/AI9-Manga-Colorizer"
  SOURCE_DIR="$INSTALL_DIR/.sources"
  AI9_SRC="$SOURCE_DIR/AI9"
  UPSTREAM_SRC="$SOURCE_DIR/Manga-Colorizer"
  VENV_DIR="$INSTALL_DIR/venv"
  VENV_PY="$VENV_DIR/Scripts/python.exe"
  mkdir -p "$INSTALL_DIR"
fi
mkdir -p "$SOURCE_DIR" "$INSTALL_DIR/models" "$INSTALL_DIR/cache" "$INSTALL_DIR/logs"

sync_repo() {
  local url="$1"
  local dest="$2"
  local label="$3"

  if [[ -d "$dest/.git" ]]; then
    log "Updating $label"
    "$GIT" -C "$dest" fetch --quiet origin
    "$GIT" -C "$dest" checkout --quiet main 2>/dev/null || true
    "$GIT" -C "$dest" pull --ff-only
  elif [[ -e "$dest" ]]; then
    die "$dest exists but is not a Git checkout. Move/remove it and rerun."
  else
    log "Cloning $label"
    "$GIT" clone "$url" "$dest"
  fi
}

sync_repo "$AI9_REPO" "$AI9_SRC" "AI9"
sync_repo "$UPSTREAM_REPO" "$UPSTREAM_SRC" "upstream Manga-Colorizer"

log "Forging the AI9 runtime: backend + Firefox extension"
mkdir -p "$INSTALL_DIR/backend" "$INSTALL_DIR/extension" "$INSTALL_DIR/deploy" "$INSTALL_DIR/tools"

# Start from upstream so bundled denoiser/upscaler assets are present.
cp -a "$UPSTREAM_SRC/Backend/." "$INSTALL_DIR/backend/"
cp -a "$UPSTREAM_SRC/Frontend-Firefox/." "$INSTALL_DIR/extension/"

# Overlay AI9's patched files.
cp -a "$AI9_SRC/backend/." "$INSTALL_DIR/backend/"
cp -a "$AI9_SRC/extension/." "$INSTALL_DIR/extension/"
cp -a "$AI9_SRC/deploy/." "$INSTALL_DIR/deploy/"
if [[ -d "$AI9_SRC/tools" ]]; then
  cp -a "$AI9_SRC/tools/." "$INSTALL_DIR/tools/"
fi
ok "Source tree synchronized"

# Make start_server.ps1 portable instead of relying on C:\opt\manga-colorizer.
"$PYTHON" - "$(winpath "$INSTALL_DIR/deploy/start_server.ps1")" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
old = "$root = 'C:\\opt\\manga-colorizer'"
new = "$root = Split-Path -Parent $PSScriptRoot"
if old in text:
    p.write_text(text.replace(old, new), encoding="utf-8")
PY

log "Preparing the AI9 Python environment"
if [[ ! -x "$VENV_PY" ]]; then
  "$PYTHON" -m venv "$(winpath "$VENV_DIR")"
fi
[[ -x "$VENV_PY" ]] || die "venv creation failed."
ok "venv: $VENV_DIR"

"$VENV_PY" -m pip install --upgrade pip setuptools wheel

log "Installing AI9 Python dependencies"
"$VENV_PY" -m pip install -r "$(winpath "$INSTALL_DIR/backend/requirements.txt")"

if "$VENV_PY" -c "import einops" >/dev/null 2>&1; then
  ok "einops already installed"
else
  "$VENV_PY" -m pip install einops
fi

torch_matches() {
  "$VENV_PY" - "$TORCH_CUDA" <<'PY' >/dev/null 2>&1
import sys
wanted = sys.argv[1]
try:
    import torch, torchvision
except Exception:
    raise SystemExit(1)
cuda = torch.version.cuda or ""
raise SystemExit(0 if cuda.startswith(wanted) else 1)
PY
}

if torch_matches; then
  ok "Matching PyTorch CUDA $TORCH_CUDA build already installed"
else
  log "Installing PyTorch for $GPU_FAMILY ($TORCH_FLAVOR)"
  "$VENV_PY" -m pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
  "$VENV_PY" -m pip install torch torchvision \
    --index-url "https://download.pytorch.org/whl/$TORCH_FLAVOR"
fi

log "Antonio G. Garcia GPU trial: verifying CUDA kernels and cuDNN"
if ! "$VENV_PY" "$(winpath "$INSTALL_DIR/backend/gpu_check.py")"; then
  warn "GPU probe failed once. Reinstalling the selected PyTorch build cleanly and retrying."
  "$VENV_PY" -m pip uninstall -y torch torchvision torchaudio || true
  "$VENV_PY" -m pip install --no-cache-dir torch torchvision \
    --index-url "https://download.pytorch.org/whl/$TORCH_FLAVOR"
  "$VENV_PY" "$(winpath "$INSTALL_DIR/backend/gpu_check.py")" || \
    die "GPU validation still failed. The likely cause is an NVIDIA driver/PyTorch architecture mismatch."
fi
ok "GPU inference validation passed"

valid_generator_zip() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  "$VENV_PY" - "$(winpath "$file")" <<'PY' >/dev/null 2>&1
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        bad = z.testzip()
        if bad is not None:
            raise RuntimeError(bad)
except Exception:
    raise SystemExit(1)
PY
}

MODEL_BACKEND="$INSTALL_DIR/backend/networks/generator.zip"
MODEL_PERSIST="$INSTALL_DIR/models/generator.zip"

log "Checking AI9 neural weights"
if valid_generator_zip "$MODEL_BACKEND"; then
  ok "backend/networks/generator.zip is already valid"
  if ! valid_generator_zip "$MODEL_PERSIST"; then
    cp -f "$MODEL_BACKEND" "$MODEL_PERSIST"
    ok "Created persisted models/generator.zip copy"
  fi
elif valid_generator_zip "$MODEL_PERSIST"; then
  mkdir -p "$(dirname "$MODEL_BACKEND")"
  cp -f "$MODEL_PERSIST" "$MODEL_BACKEND"
  ok "Restored generator.zip from persisted model copy"
else
  log "Generator weights are missing; downloading the upstream checkpoint"
  if ! "$VENV_PY" -c "import gdown" >/dev/null 2>&1; then
    "$VENV_PY" -m pip install gdown
  fi

  TMP_MODEL="$INSTALL_DIR/models/generator.zip.part"
  rm -f "$TMP_MODEL"
  "$VENV_PY" -m gdown \
    "https://drive.google.com/uc?id=$GENERATOR_FILE_ID" \
    -O "$(winpath "$TMP_MODEL")"

  valid_generator_zip "$TMP_MODEL" || \
    die "Downloaded generator checkpoint is not a valid ZIP. Google Drive may have returned an error/quota page."

  mv -f "$TMP_MODEL" "$MODEL_PERSIST"
  mkdir -p "$(dirname "$MODEL_BACKEND")"
  cp -f "$MODEL_PERSIST" "$MODEL_BACKEND"
  ok "Generator weights downloaded and verified"
fi

# Sanity-check the two smaller upstream assets too.
[[ -f "$INSTALL_DIR/backend/networks/RealESRGAN_x4plus_anime_6B.pt" ]] || \
  die "Missing upstream RealESRGAN checkpoint."
[[ -f "$INSTALL_DIR/backend/denoising/models/net_rgb.pth" ]] || \
  die "Missing upstream denoiser checkpoint."
ok "Bundled upscaler and denoiser assets present"

if [[ "$INSTALL_FIREFOX" == "1" ]]; then
  FIREFOX_FOUND=0
  for f in \
    "/c/Program Files/Mozilla Firefox/firefox.exe" \
    "/c/Program Files (x86)/Mozilla Firefox/firefox.exe"
  do
    [[ -x "$f" ]] && FIREFOX_FOUND=1
  done
  if [[ "$FIREFOX_FOUND" == "1" ]]; then
    ok "Firefox already installed"
  else
    log "Firefox is missing; installing it"
    winget_install "Mozilla.Firefox"
  fi
fi

if [[ "$REGISTER_TASK" == "1" ]]; then
  command_exists powershell.exe || die "powershell.exe was not found."
  log "Registering the OTACONSKEEP AI9 Windows service task"
  powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "$(winpath "$INSTALL_DIR/deploy/register-task.ps1")"
fi

log "Bringing AI9 online and checking system health"
HEALTH_OK=0
for _ in $(seq 1 20); do
  if curl -kfsS --max-time 2 https://127.0.0.1:5000/ 2>/dev/null | grep -qi "Manga Colorizer"; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done

if [[ "$HEALTH_OK" == "1" ]]; then
  ok "Backend is healthy at https://127.0.0.1:5000/"
else
  warn "Install finished, but the backend health check did not answer yet."
  warn "Check: $INSTALL_DIR/logs/"
fi

LAN_IP="$(powershell.exe -NoProfile -Command \
  "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.IPAddress -notmatch '^(127\.|169\.254\.)' -and \$_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1 -ExpandProperty IPAddress)" \
  2>/dev/null | tr -d '\r' || true)"

printf '\n\033[1;35m============================================================\033[0m\n'
printf '\033[1;35m ANTONIO G. GARCIA // OTACONSKEEP — AI9 ONLINE\033[0m\n'
printf '\033[0;37m                 Built for the Keep.\033[0m\n'
printf '\033[1;35m============================================================\033[0m\n'
printf 'Install folder : %s\n' "$INSTALL_DIR"
printf 'GPU            : %s\n' "$GPU_NAME"
printf 'PyTorch CUDA   : %s (%s)\n' "$TORCH_CUDA" "$TORCH_FLAVOR"
printf 'Local API      : https://127.0.0.1:5000/\n'
if [[ -n "$LAN_IP" ]]; then
  printf 'LAN API        : https://%s:5000/\n' "$LAN_IP"
fi
printf 'Firefox addon  : %s\n' "$INSTALL_DIR/extension/manifest.json"
printf 'Logs           : %s\n' "$INSTALL_DIR/logs"
printf '\nFirefox still requires the unsigned extension to be loaded manually:\n'
printf '  about:debugging#/runtime/this-firefox -> Load Temporary Add-on\n'
printf '  choose: %s\n' "$INSTALL_DIR/extension/manifest.json"
printf '\n[ANTONIO G. GARCIA] Rerunning this installer is safe; completed steps are reused/skipped where possible.\n'
printf '[ANTONIO G. GARCIA] AI9 deployment complete. Welcome to the Keep.\n'
