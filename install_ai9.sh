#!/usr/bin/env bash
set -Eeuo pipefail

BRAND="ANTONIO G. GARCIA // OTACONSKEEP"
PRODUCT="AI9 AUTOMATED INSTALLER"
TAGLINE="Built for the Keep."

# AI9 / Manga-Colorizer one-shot Windows installer
# Target shell: Git Bash on Windows 10/11
#
# What it does:
#   - Installs Python 3.12 if missing (prefers Python.Python.3.12 via winget)
#   - Installs/updates AI9 + upstream Manga-Colorizer source
#   - Builds the deployed backend/extension tree
#   - Detects RTX 30/40/50-series GPU
#   - Selects an appropriate PyTorch CUDA wheel
#   - Creates/reuses a venv and installs Python dependencies
#   - Downloads/verifies generator.zip (ZIP + optional SHA256) if missing
#   - Runs AI9's real GPU kernel/cuDNN probe
#   - Registers/starts the Windows Scheduled Task
#   - Health-checks the backend and runs an E2E colorize inference probe
#   - Exits READY(0) / DEGRADED(2) / FAILED(1) — never prints ONLINE on failure
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
printf '\033[0;37m%s :: %s\033[0m\n\n' "$PRODUCT" "$TAGLINE"

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
  [[ -n "$WINGET" ]] || die "winget is unavailable. What to do: install 'App Installer' from the Microsoft Store (https://apps.microsoft.com/detail/9nblggh4nns1), then close this window and double-click install_ai9.bat again."
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
  [[ -n "$GIT" ]] || die "Git installed but is not visible yet. What to do: close this window completely, then double-click install_ai9.bat again (Windows needs a fresh window to see newly installed programs)."
fi
ok "Git: $("$GIT" --version)"

# Preferred runtime is Python 3.12.x. 3.10/3.11 remain "usable" only so an
# already-working older install can continue with a warning.
python_is_usable() {
  local exe="$1"
  "$exe" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

python_is_preferred() {
  local exe="$1"
  "$exe" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)' >/dev/null 2>&1
}

find_python() {
  local p preferred="" fallback=""
  for p in \
    "/c/Users/${USERNAME:-}/AppData/Local/Programs/Python/Python312/python.exe" \
    "/c/Program Files/Python312/python.exe" \
    "$(command -v python3.12 2>/dev/null || true)" \
    "$(command -v python.exe 2>/dev/null || true)" \
    "$(command -v python 2>/dev/null || true)" \
    "/c/Users/${USERNAME:-}/AppData/Local/Programs/Python/Python311/python.exe" \
    "/c/Users/${USERNAME:-}/AppData/Local/Programs/Python/Python310/python.exe" \
    "/c/Program Files/Python311/python.exe" \
    "/c/Program Files/Python310/python.exe"
  do
    [[ -n "$p" && -x "$p" ]] || continue
    python_is_usable "$p" || continue
    if python_is_preferred "$p"; then
      preferred="$p"
      break
    fi
    [[ -z "$fallback" ]] && fallback="$p"
  done
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return 0
  fi
  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

log "OTACONSKEEP preflight: checking Python 3.12"
PYTHON="$(find_python || true)"
if [[ -z "$PYTHON" ]]; then
  log "Python 3.12 is missing; installing Python.Python.3.12 via winget"
  winget_install "Python.Python.3.12"
  PYTHON="$(find_python || true)"
  [[ -n "$PYTHON" ]] || die "Python 3.12 installed but could not be located. What to do: close this window completely, then double-click install_ai9.bat again."
  python_is_preferred "$PYTHON" || die "Fresh install requires Python 3.12.x, but found: $("$PYTHON" --version 2>&1). What to do: install Python.Python.3.12 from winget, then rerun."
elif ! python_is_preferred "$PYTHON"; then
  warn "Preferred runtime is Python 3.12.x; found $("$PYTHON" --version 2>&1). Continuing with the existing interpreter because it is already usable (3.10+)."
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
[[ -n "$NVIDIA_SMI" ]] || die "nvidia-smi was not found -- this usually means the NVIDIA GPU driver isn't installed. What to do: go to https://www.nvidia.com/download/index.aspx, download and install the driver for your specific GPU model, restart your PC, then double-click install_ai9.bat again. (You do NOT need to separately install anything called 'CUDA Toolkit' -- the driver alone is enough.)"

GPU_NAME="$("$NVIDIA_SMI" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | tr -d '\r')"
[[ -n "$GPU_NAME" ]] || die "Could not identify the NVIDIA GPU with nvidia-smi."

read_cuda_max() {
  local smi="$1" raw v
  # On some Windows drivers the banner (with CUDA Version) lands on stderr.
  raw="$("$smi" 2>&1 | tr -d '\r')"
  v="$(printf '%s\n' "$raw" | sed -nE 's/.*[Cc][Uu][Dd][Aa][[:space:]]+[Vv]ersion[^0-9]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  v="$(printf '%s\n' "$raw" | grep -i 'cuda version' | sed -nE 's/.*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  v="$("$smi" -q 2>/dev/null | sed -nE 's/^[[:space:]]*CUDA Version[^0-9]*:?[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1 | tr -d '\r')"
  [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  return 1
}

CUDA_MAX="$(read_cuda_max "$NVIDIA_SMI" || true)"
[[ -n "$CUDA_MAX" ]] || die "Could not read the driver's maximum CUDA version from nvidia-smi. What to do: open Command Prompt, run nvidia-smi, and confirm it prints a CUDA Version line. If it does not, install or update your NVIDIA GPU driver from https://www.nvidia.com/download/index.aspx, restart, then double-click AI9 Setup again."

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
      die "Found your $GPU_NAME, but its NVIDIA driver is out of date (reports CUDA $CUDA_MAX, needs 12.1+). What to do: go to https://www.nvidia.com/download/index.aspx, download and install the latest driver for your GPU, restart your PC, then double-click install_ai9.bat again."
    fi
    ;;
  *"RTX 30"*)
    TORCH_FLAVOR="cu118"
    TORCH_CUDA="11.8"
    MIN_DRIVER_CUDA="11.8"
    GPU_FAMILY="RTX 30-series / Ampere"
    ;;
  *)
    die "Your GPU ('$GPU_NAME') isn't one this installer auto-configures yet -- it currently supports NVIDIA RTX 30, 40, and 50-series cards. If you have one of those and this is a false detection, or you have a different NVIDIA card and know what you're doing, see the 'Manual setup' section in README.md to install PyTorch by hand."
    ;;
esac

version_ge "$CUDA_MAX" "$MIN_DRIVER_CUDA" || \
  die "Your $GPU_NAME needs a newer NVIDIA driver (it reports supporting only CUDA $CUDA_MAX, needs $MIN_DRIVER_CUDA+). What to do: go to https://www.nvidia.com/download/index.aspx, download and install the latest driver for your GPU, restart your PC, then double-click install_ai9.bat again."

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

"$VENV_PY" -m pip install --upgrade "pip" "setuptools>=70,<82" "wheel"

log "Installing AI9 Python dependencies"
REQ_FILE="$INSTALL_DIR/backend/requirements-lock.txt"
[[ -f "$REQ_FILE" ]] || REQ_FILE="$INSTALL_DIR/backend/requirements.txt"
"$VENV_PY" -m pip install -r "$(winpath "$REQ_FILE")"
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

# Torch 2.11+ declares setuptools<82; keep the pin even if a wheel pulled newer.
"$VENV_PY" -m pip install --upgrade "setuptools>=70,<82" >/dev/null
ok "setuptools pinned to Torch-compatible range (<82)"

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

log "Ensuring per-install TLS certificate (unique; never reused from Git)"
"$VENV_PY" "$(winpath "$INSTALL_DIR/backend/ensure_ssl.py")" "$(winpath "$INSTALL_DIR/backend/ssl")"
ok "TLS materials ready under backend/ssl/ (private key is not logged)"

CHECKSUMS_FILE="$INSTALL_DIR/backend/checksums.json"

expected_sha256() {
  local key="$1"
  "$VENV_PY" - "$CHECKSUMS_FILE" "$key" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path, key = Path(sys.argv[1]), sys.argv[2]
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
entry = (data.get("files") or {}).get(key) or {}
print(str(entry.get("sha256") or "").strip())
PY
}

sha256_is_published() {
  local digest="$1"
  case "$digest" in
    ""|PENDING|pending|TODO|todo) return 1 ;;
    *) return 0 ;;
  esac
}

file_sha256_hex() {
  local file="$1"
  "$VENV_PY" - "$(winpath "$file")" <<'PY'
import hashlib, sys
from pathlib import Path
h = hashlib.sha256()
with Path(sys.argv[1]).open("rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
}

verify_published_sha256() {
  local file="$1"
  local expected="$2"
  local label="$3"
  sha256_is_published "$expected" || return 0
  local actual
  actual="$(file_sha256_hex "$file" | tr -d '\r\n' | tr 'A-F' 'a-f')"
  expected="$(printf '%s' "$expected" | tr -d '\r\n' | tr 'A-F' 'a-f')"
  [[ "$actual" == "$expected" ]] || {
    warn "SHA256 mismatch for $label (got $actual, expected $expected)"
    return 1
  }
  return 0
}

valid_generator_zip() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  if ! "$VENV_PY" - "$(winpath "$file")" <<'PY' >/dev/null 2>&1
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        bad = z.testzip()
        if bad is not None:
            raise RuntimeError(bad)
except Exception:
    raise SystemExit(1)
PY
  then
    return 1
  fi
  local expected
  expected="$(expected_sha256 "generator.zip")"
  if sha256_is_published "$expected"; then
    verify_published_sha256 "$file" "$expected" "generator.zip" || return 1
  fi
  return 0
}

download_generator_zip() {
  local dest="$1"
  if ! "$VENV_PY" -c "import gdown" >/dev/null 2>&1; then
    "$VENV_PY" -m pip install gdown
  fi
  local tmp="$dest.part"
  rm -f "$tmp"
  "$VENV_PY" -m gdown \
    "https://drive.google.com/uc?id=$GENERATOR_FILE_ID" \
    -O "$(winpath "$tmp")"
  mv -f "$tmp" "$dest"
}

ensure_generator_zip() {
  local target="$1"
  if valid_generator_zip "$target"; then
    return 0
  fi
  if [[ -f "$target" ]]; then
    warn "Removing invalid/corrupt generator.zip before retry"
    rm -f "$target"
  fi
  log "Downloading generator.zip"
  download_generator_zip "$target"
  if valid_generator_zip "$target"; then
    return 0
  fi
  warn "generator.zip failed verification; deleting and retrying download once"
  rm -f "$target"
  download_generator_zip "$target"
  valid_generator_zip "$target" || \
    die "generator.zip failed ZIP/SHA256 verification after one retry. Google Drive may have returned an error/quota page, or the published checksum does not match."
}

MODEL_BACKEND="$INSTALL_DIR/backend/networks/generator.zip"
MODEL_PERSIST="$INSTALL_DIR/models/generator.zip"
ASSETS_OK=1

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
  log "Generator weights are missing or failed integrity checks"
  mkdir -p "$(dirname "$MODEL_PERSIST")" "$(dirname "$MODEL_BACKEND")"
  ensure_generator_zip "$MODEL_PERSIST"
  cp -f "$MODEL_PERSIST" "$MODEL_BACKEND"
  ok "Generator weights downloaded and verified"
fi

verify_sidecar_asset() {
  local file="$1"
  local key="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    die "Missing upstream $label ($file)."
  fi
  local expected
  expected="$(expected_sha256 "$key")"
  if sha256_is_published "$expected"; then
    if ! verify_published_sha256 "$file" "$expected" "$label"; then
      ASSETS_OK=0
      die "SHA256 mismatch for $label. Existence alone is not enough when a digest is published. Re-sync upstream assets or update checksums.json."
    fi
    ok "$label present and SHA256 matches"
  else
    ok "$label present (SHA256 not published yet)"
  fi
}

verify_sidecar_asset \
  "$INSTALL_DIR/backend/networks/RealESRGAN_x4plus_anime_6B.pt" \
  "RealESRGAN_x4plus_anime_6B.pt" \
  "RealESRGAN_x4plus_anime_6B.pt"
verify_sidecar_asset \
  "$INSTALL_DIR/backend/denoising/models/net_rgb.pth" \
  "denoising/models/net_rgb.pth" \
  "net_rgb.pth"
ok "Bundled upscaler and denoiser assets verified"
BROWSER_STATUS="not_ready"
FIREFOX_STATUS="skipped"
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
    FIREFOX_STATUS="installed"
  else
    log "Firefox is missing; installing it"
    if winget_install "Mozilla.Firefox"; then
      FIREFOX_FOUND=0
      for f in \
        "/c/Program Files/Mozilla Firefox/firefox.exe" \
        "/c/Program Files (x86)/Mozilla Firefox/firefox.exe"
      do
        [[ -x "$f" ]] && FIREFOX_FOUND=1
      done
      if [[ "$FIREFOX_FOUND" == "1" ]]; then
        ok "Firefox installed"
        FIREFOX_STATUS="installed"
      else
        warn "Firefox install was attempted but firefox.exe is not visible yet."
        FIREFOX_STATUS="missing"
      fi
    else
      warn "Firefox install via winget failed."
      FIREFOX_STATUS="missing"
    fi
  fi
  # Temporary Add-on load cannot be automated; never claim browser READY.
  BROWSER_STATUS="not_ready"
  warn "Browser integration remains not_ready (Firefox temporary unsigned extension must be loaded manually)."
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

INFERENCE_OK=0
if [[ "$HEALTH_OK" == "1" ]]; then
  ok "Backend is healthy at https://127.0.0.1:5000/"
  log "Running E2E inference probe against /colorize-image-data"
  PROBE_PNG="$INSTALL_DIR/backend/testdata/installer_probe.png"
  if [[ ! -f "$PROBE_PNG" ]]; then
    warn "Missing installer probe image at $PROBE_PNG"
  else
    if "$VENV_PY" - "$(winpath "$PROBE_PNG")" <<'PY'
import base64, json, ssl, sys, urllib.error, urllib.request
from pathlib import Path

try:
    from PIL import Image
    import io
except Exception as exc:
    print(f"PROBE_FAIL pillow import: {exc}")
    raise SystemExit(1)

probe = Path(sys.argv[1])
raw = probe.read_bytes()
img = Image.open(io.BytesIO(raw))
w, h = img.size
if w <= 0 or h <= 0:
    print("PROBE_FAIL invalid probe dimensions")
    raise SystemExit(1)

payload = {
    "imgName": "installer-probe",
    "imgData": "data:image/png;base64," + base64.b64encode(raw).decode("ascii"),
    "imgWidth": w,
    "imgHeight": h,
    "colorize": True,
    "denoise": False,
    "upscale": False,
    "cache": False,
}
req = urllib.request.Request(
    "https://127.0.0.1:5000/colorize-image-data",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
ctx = ssl._create_unverified_context()
try:
    with urllib.request.urlopen(req, context=ctx, timeout=300) as resp:
        status = getattr(resp, "status", None) or resp.getcode()
        body = resp.read()
except Exception as exc:
    print(f"PROBE_FAIL request: {exc}")
    raise SystemExit(1)

if int(status) < 200 or int(status) >= 300:
    print(f"PROBE_FAIL http {status}")
    raise SystemExit(1)

try:
    data = json.loads(body.decode("utf-8"))
except Exception as exc:
    print(f"PROBE_FAIL json: {exc}")
    raise SystemExit(1)

color = data.get("colorImgData") or ""
if not color or "," not in color:
    print(f"PROBE_FAIL missing colorImgData: {data!r}"[:500])
    raise SystemExit(1)
meta, b64 = color.split(",", 1)
try:
    out_bytes = base64.b64decode(b64)
    out = Image.open(io.BytesIO(out_bytes))
    out.load()
except Exception as exc:
    print(f"PROBE_FAIL decode image: {exc}")
    raise SystemExit(1)
ow, oh = out.size
if ow <= 0 or oh <= 0:
    print(f"PROBE_FAIL bad output size {ow}x{oh}")
    raise SystemExit(1)
print(f"PROBE_OK {ow}x{oh}")
raise SystemExit(0)
PY
    then
      INFERENCE_OK=1
      ok "E2E inference probe passed"
    else
      warn "E2E inference probe failed"
    fi
  fi
else
  warn "Backend health check did not answer."
  warn "Check: $INSTALL_DIR/logs/"
fi

# Status model: READY (0) / DEGRADED (2) / FAILED (1)
GPU_OK=1
INSTALL_STATUS="READY"
EXIT_CODE=0

if [[ "$ASSETS_OK" != "1" || "$HEALTH_OK" != "1" || "$INFERENCE_OK" != "1" ]]; then
  INSTALL_STATUS="FAILED"
  EXIT_CODE=1
elif [[ "$INSTALL_FIREFOX" == "1" && "$FIREFOX_STATUS" == "missing" ]]; then
  INSTALL_STATUS="DEGRADED"
  EXIT_CODE=2
fi

# Production default is localhost-only (127.0.0.1). Do not advertise LAN URLs.
printf '\n\033[1;35m============================================================\033[0m\n'
case "$INSTALL_STATUS" in
  READY)
    printf '\033[1;35m ANTONIO G. GARCIA // OTACONSKEEP :: AI9 ONLINE\033[0m\n'
    printf '\033[1;32m Status         : READY\033[0m\n'
    ;;
  DEGRADED)
    printf '\033[1;33m ANTONIO G. GARCIA // OTACONSKEEP :: AI9 DEGRADED\033[0m\n'
    printf '\033[1;33m Status         : DEGRADED\033[0m\n'
    ;;
  *)
    printf '\033[1;31m ANTONIO G. GARCIA // OTACONSKEEP :: AI9 FAILED\033[0m\n'
    printf '\033[1;31m Status         : FAILED\033[0m\n'
    ;;
esac
printf '\033[0;37m                 Built for the Keep.\033[0m\n'
printf '\033[1;35m============================================================\033[0m\n'
printf 'Install folder : %s\n' "$INSTALL_DIR"
printf 'GPU            : %s\n' "$GPU_NAME"
printf 'PyTorch CUDA   : %s (%s)\n' "$TORCH_CUDA" "$TORCH_FLAVOR"
printf 'GPU check      : %s\n' "$([[ "$GPU_OK" == "1" ]] && echo pass || echo fail)"
printf 'Asset integrity: %s\n' "$([[ "$ASSETS_OK" == "1" ]] && echo pass || echo fail)"
printf 'Backend health : %s\n' "$([[ "$HEALTH_OK" == "1" ]] && echo pass || echo fail)"
printf 'E2E inference  : %s\n' "$([[ "$INFERENCE_OK" == "1" ]] && echo pass || echo fail)"
printf 'Browser integ. : %s (temporary extension cannot be auto-loaded)\n' "$BROWSER_STATUS"
printf 'Firefox        : %s\n' "$FIREFOX_STATUS"
printf 'Local API      : https://127.0.0.1:5000/\n'
printf 'Logs           : %s\n' "$INSTALL_DIR/logs"
printf 'Doctor         : "%s" "%s"\n' \
  "$(winpath "$VENV_PY")" \
  "$(winpath "$INSTALL_DIR/tools/ai9_doctor.py")"

printf '\n\033[1;36mHTTPS note:\033[0m The backend uses a per-install self-signed certificate\n'
printf '  (generated uniquely on this PC; not shared across installs).\n'
printf '  Your browser / OS will require a one-time trust decision for\n'
printf '  https://127.0.0.1:5000/.\n'
printf '  This does not mean the connection is publicly trusted — only that\n'
printf '  this local AI9 endpoint can speak HTTPS after you accept its cert.\n'
printf '  The API listens on localhost only; other machines on your LAN cannot\n'
printf '  reach it.\n'

MANIFEST_WINPATH="$(winpath "$INSTALL_DIR/extension/manifest.json")"
printf '\n\033[1;33m============================================================\033[0m\n'
printf '\033[1;33m ONE LAST STEP (a browser cannot do this part automatically):\033[0m\n'
printf '\033[1;33m============================================================\033[0m\n'
printf '  Browser integration status: \033[1;33mnot_ready\033[0m until you complete this.\n'
printf '  1. Open the Firefox browser (not any other browser).\n'
printf '  2. Click the address bar at the top, type this exactly, and press Enter:\n'
printf '       \033[1;36mabout:debugging#/runtime/this-firefox\033[0m\n'
printf '  3. On that page, click the button labeled \033[1;36mLoad Temporary Add-on...\033[0m\n'
printf '  4. A file-picker window opens. Copy/paste this exact file path into it,\n'
printf '     then press Enter (or click Open):\n'
printf '       \033[1;36m%s\033[0m\n' "$MANIFEST_WINPATH"
printf '  5. You should now see "AI9 Manga Colorizer" (or similar) listed on that\n'
printf '     page. That means it worked. Open a manga page in a new tab and start\n'
printf '     reading -- pages should start colorizing automatically.\n'
printf '\n  Note: Firefox forgets this extension every time it fully restarts,\n'
printf '  since it is unsigned. If colorizing stops working after a Firefox\n'
printf '  restart, just repeat steps 1-4 above -- it takes 30 seconds.\n'
printf '\n[ANTONIO G. GARCIA] Rerunning this installer is safe; completed steps are reused/skipped where possible.\n'
printf '[ANTONIO G. GARCIA] Post-install doctor: tools/ai9_doctor.py (GPU, models/hashes, port 5000, /healthz, extension note).\n'
if [[ "$INSTALL_STATUS" == "READY" ]]; then
  printf '[ANTONIO G. GARCIA] AI9 deployment READY. Welcome to the Keep.\n'
elif [[ "$INSTALL_STATUS" == "DEGRADED" ]]; then
  printf '[ANTONIO G. GARCIA] AI9 core is up but the install is DEGRADED (see Firefox/browser notes above).\n'
else
  printf '[ANTONIO G. GARCIA] AI9 deployment FAILED. Health and/or E2E inference did not pass — not marking ONLINE.\n'
fi

exit "$EXIT_CODE"
