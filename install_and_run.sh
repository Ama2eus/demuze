#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Demuze — Smart Installer & Launcher  (macOS / Linux)
#  v2.2 — Pinned torch==2.2.2 / torchaudio==2.2.2 to fix torchcodec crash
#
#  ROOT CAUSE OF CRASH:
#    torchaudio 2.3+ routes ALL audio saving through torchcodec.
#    torchcodec is NOT installed with demucs.
#    Result: "ImportError: TorchCodec is required for save_with_torchcodec"
#
#  FIX:
#    Force torch==2.2.2 + torchaudio==2.2.2 (last version using soundfile).
#    Uninstall any newer torchaudio that pip may have auto-upgraded to.
#    All installs use MAX_JOBS=1 OMP_NUM_THREADS=1 to avoid RAM crash.
#
#  LEGAL: FFmpeg checked on PATH + OS package manager only. Never bundled.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PORT="${PORT:-8000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Pinned versions ────────────────────────────────────────────────────────────
TORCH_VERSION="2.2.2"
TORCHAUDIO_VERSION="2.2.2"

# Colours
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' C='\033[0;36m' B='\033[1m' D='\033[2m' N='\033[0m'
ok()   { echo -e "  ${G}✓${N}  $*"; }
warn() { echo -e "  ${Y}⚠${N}  $*"; }
err()  { echo -e "  ${R}✗${N}  $*"; exit 1; }
info() { echo -e "  ${C}→${N}  $*"; }
step() { echo -e "\n${B}  [$1/7] $2${N}\n  ${D}────────────────────────────────────────${N}"; }

clear
echo ""
echo -e "${B}  DEMUZE — Offline Audio Stem Separator${N}"
echo -e "  ${C}Powered by Demucs htdemucs_6s · 100%% Offline · MIT License${N}"
echo -e "  ${D}torch==${TORCH_VERSION}  torchaudio==${TORCHAUDIO_VERSION}  (pinned for soundfile backend)${N}"
echo ""

# ════════════════════════════════════════════════════════════════════
# STEP 1 — System diagnostics
# ════════════════════════════════════════════════════════════════════
step 1 "System diagnostics"

OS="unknown"
if   [[ "$OSTYPE" == "darwin"* ]];                         then OS="macos";  ok "macOS"
elif [[ -f /etc/debian_version ]];                         then OS="debian"; ok "Debian / Ubuntu"
elif [[ -f /etc/fedora-release || -f /etc/redhat-release ]]; then OS="fedora"; ok "Fedora / RHEL"
elif [[ -f /etc/arch-release ]];                           then OS="arch";   ok "Arch Linux"
else warn "Unknown OS — package auto-install may not work"; fi

# RAM check
RAM_MB=0
if   [[ "$OS" == "macos" ]]; then RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
elif command -v free &>/dev/null; then RAM_MB=$(free -m | awk '/^Mem:/{print $2}'); fi

if   [[ $RAM_MB -ge 16000 ]]; then ok "RAM: ${RAM_MB} MB"
elif [[ $RAM_MB -ge  8000 ]]; then ok "RAM: ${RAM_MB} MB — adequate"
elif [[ $RAM_MB -ge  4000 ]]; then warn "RAM: ${RAM_MB} MB — limited, using CPU-only PyTorch"
elif [[ $RAM_MB -gt     0 ]]; then warn "RAM: ${RAM_MB} MB — very low, using CPU-only PyTorch"
else warn "RAM unknown — defaulting to CPU-only PyTorch (safe)"; fi

# GPU / torch index decision
TORCH_INDEX="https://download.pytorch.org/whl/cpu"
TORCH_VARIANT="cpu"

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
  ok "NVIDIA GPU: $GPU_NAME"
  if [[ $RAM_MB -ge 8000 || $RAM_MB -eq 0 ]]; then
    echo ""
    echo -e "  ${B}PyTorch variant for torch==${TORCH_VERSION}:${N}"
    echo "    [1] CPU-only  ~ 180 MB   safe, always works   (default)"
    echo "    [2] CUDA GPU  ~ 2.4 GB   5-15x faster"
    echo ""
    read -r -t 20 -p "  Choice (1/2, auto-CPU in 20s): " GPU_CHOICE </dev/tty || GPU_CHOICE="1"
    if [[ "${GPU_CHOICE:-1}" == "2" ]]; then
      CUDA_VER=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[\d]+' || echo "12")
      [[ "$CUDA_VER" -ge 12 ]] \
        && TORCH_INDEX="https://download.pytorch.org/whl/cu121" \
        || TORCH_INDEX="https://download.pytorch.org/whl/cu118"
      TORCH_VARIANT="cuda"
      ok "CUDA PyTorch selected (index: $TORCH_INDEX)"
    else ok "CPU PyTorch selected"; fi
  else warn "Low RAM — forcing CPU PyTorch"; fi
elif [[ "$OS" == "macos" && "$(uname -m)" == "arm64" ]]; then
  ok "Apple Silicon — MPS acceleration included in macOS torch"
else ok "CPU PyTorch (works for all hardware)"; fi

# ════════════════════════════════════════════════════════════════════
# STEP 2 — Python 3.10–3.12
# ════════════════════════════════════════════════════════════════════
step 2 "Python runtime (3.10–3.12 required by PyTorch)"

PY_CMD=""
for c in python3.12 python3.11 python3.10 python3 python; do
  if command -v "$c" &>/dev/null; then
    v=$("$c" -c "import sys; x=sys.version_info; print(f'{x.major}.{x.minor}')" 2>/dev/null || echo "0.0")
    maj="${v%%.*}"; min="${v##*.}"
    if [[ "$maj" == "3" && "$min" -ge 10 && "$min" -le 12 ]]; then
      PY_CMD="$c"; ok "Found: $c (Python $v)"; break
    fi
  fi
done

if [[ -z "$PY_CMD" ]]; then
  warn "No compatible Python (3.10–3.12) — attempting auto-install…"
  case "$OS" in
    macos)
      command -v brew &>/dev/null \
        && { brew install python@3.12; PY_CMD="python3.12"; } \
        || err "Install Homebrew (https://brew.sh) then rerun" ;;
    debian)
      sudo apt-get update -qq
      sudo apt-get install -y python3.12 python3.12-venv python3.12-dev
      PY_CMD="python3.12" ;;
    fedora)
      sudo dnf install -y python3.12 python3.12-devel; PY_CMD="python3.12" ;;
    arch)
      sudo pacman -S --noconfirm python python-pip; PY_CMD="python" ;;
    *)
      echo "  Install Python 3.12 from: https://www.python.org/downloads"
      echo "  Python 3.13/3.14 are NOT supported by PyTorch."
      err "Cannot auto-install Python on this OS" ;;
  esac
  ok "Python installed: $PY_CMD"
fi

"$PY_CMD" -m pip --version &>/dev/null || "$PY_CMD" -m ensurepip --upgrade 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════
# STEP 3 — FFmpeg  (LEGAL: OS package manager only, never bundled)
# ════════════════════════════════════════════════════════════════════
step 3 "FFmpeg — external LGPL tool (installed via OS package manager)"

if command -v ffmpeg &>/dev/null && ffmpeg -version &>/dev/null 2>&1; then
  ok "FFmpeg: $(ffmpeg -version 2>&1 | head -1)"
else
  warn "FFmpeg not found — installing via package manager (LGPL build)…"
  case "$OS" in
    macos)
      command -v brew &>/dev/null \
        && brew install ffmpeg \
        || err "Install Homebrew first: https://brew.sh" ;;
    debian) sudo apt-get install -y ffmpeg ;;
    fedora)
      rpm -q rpmfusion-free-release &>/dev/null || \
        sudo dnf install -y \
          "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
          2>/dev/null || true
      sudo dnf install -y ffmpeg ;;
    arch) sudo pacman -S --noconfirm ffmpeg ;;
    *) err "Cannot auto-install FFmpeg. Get it from https://ffmpeg.org/download.html" ;;
  esac
  ffmpeg -version &>/dev/null 2>&1 && ok "FFmpeg installed" || err "FFmpeg install failed"
fi

# ════════════════════════════════════════════════════════════════════
# STEP 4 — Virtual environment
# ════════════════════════════════════════════════════════════════════
step 4 "Python virtual environment"

VENV="$SCRIPT_DIR/.venv"
if [[ ! -d "$VENV" ]]; then
  info "Creating .venv/ with $PY_CMD …"
  "$PY_CMD" -m venv "$VENV"
  ok "Virtualenv created"
else
  ok "Virtualenv exists"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

# ════════════════════════════════════════════════════════════════════
# STEP 5 — RAM-safe pinned package installation
#
#  KEY FIXES vs previous version:
#  1. torch==2.2.2 torchaudio==2.2.2 — PINNED to last soundfile-backend version
#  2. Force-uninstall any newer torchaudio before installing pinned version
#  3. MAX_JOBS=1 OMP_NUM_THREADS=1 etc. — prevent RAM crash from parallel builds
#  4. --no-cache-dir — no double-buffering RAM+disk during wheel unpack
#  5. torch installed ALONE first — biggest package, must not mix with others
# ════════════════════════════════════════════════════════════════════
step 5 "Installing packages (pinned versions, RAM-safe, one at a time)"

# Set all thread-limiting env vars
export MAX_JOBS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

info "Upgrading pip…"
pip install --quiet --upgrade pip

# ── 5a. Force-remove any incompatible torchaudio already installed ─────────────
echo ""
info "Checking for incompatible torchaudio (2.3+ causes torchcodec crash)…"
INSTALLED_TA=$(pip show torchaudio 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_TA" != "none" && "$INSTALLED_TA" != "$TORCHAUDIO_VERSION" ]]; then
  warn "Found torchaudio==$INSTALLED_TA — uninstalling (incompatible, causes torchcodec crash)…"
  pip uninstall -y torchaudio torch 2>/dev/null || true
  ok "Removed incompatible torch/torchaudio"
elif [[ "$INSTALLED_TA" == "$TORCHAUDIO_VERSION" ]]; then
  ok "torchaudio==$TORCHAUDIO_VERSION already installed"
fi

# ── 5b. Install pinned torch + torchaudio (largest, installed alone) ───────────
INSTALLED_T=$(pip show torch 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "none")
if [[ "$INSTALLED_T" == "$TORCH_VERSION" && "$INSTALLED_TA" == "$TORCHAUDIO_VERSION" ]]; then
  ok "torch==$TORCH_VERSION + torchaudio==$TORCHAUDIO_VERSION already installed"
else
  if [[ "$TORCH_VARIANT" == "cuda" ]]; then
    info "Installing torch==${TORCH_VERSION} CUDA (~2.4 GB) — single-threaded, please wait…"
  else
    info "Installing torch==${TORCH_VERSION} CPU-only (~180 MB) — single-threaded…"
  fi

  pip install \
    --no-cache-dir \
    "torch==${TORCH_VERSION}" \
    "torchaudio==${TORCHAUDIO_VERSION}" \
    --index-url "$TORCH_INDEX"
  ok "torch==${TORCH_VERSION} + torchaudio==${TORCHAUDIO_VERSION} installed"
fi

# ── 5c. Verify the installed version is exactly what we need ───────────────────
ACTUAL_TA=$(pip show torchaudio 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "unknown")
if [[ "$ACTUAL_TA" != "$TORCHAUDIO_VERSION" ]]; then
  err "torchaudio version mismatch: got $ACTUAL_TA, need $TORCHAUDIO_VERSION. Try deleting .venv/ and rerunning."
fi
ok "Version verified: torchaudio==$ACTUAL_TA (soundfile backend — no torchcodec needed)"

# ── 5d. FastAPI + server ───────────────────────────────────────────────────────
info "Installing FastAPI + Uvicorn…"
pip install --no-cache-dir \
  "fastapi>=0.111.0" \
  "uvicorn[standard]>=0.29.0" \
  "python-multipart>=0.0.9"
ok "FastAPI installed"

# ── 5e. soundfile ──────────────────────────────────────────────────────────────
info "Installing soundfile (torchaudio 2.2.x save backend)…"
pip install --no-cache-dir "soundfile>=0.12.1"
ok "soundfile installed"

# ── 5f. Demucs (must come after torch) ────────────────────────────────────────
info "Installing Demucs…"
pip install --no-cache-dir "demucs>=4.0.1"
ok "Demucs installed"

# ── Final verification ─────────────────────────────────────────────────────────
command -v demucs  &>/dev/null || err "demucs not found after install"
command -v uvicorn &>/dev/null || err "uvicorn not found after install"

# Quick functional test: can torchaudio save a wav without torchcodec?
info "Verifying torchaudio save backend (soundfile, not torchcodec)…"
python3 - << 'PYCHECK'
import sys, tempfile, os
try:
    import torch, torchaudio
    wav = torch.zeros(2, 16000)
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        tmp = f.name
    torchaudio.save(tmp, wav, 16000)
    os.unlink(tmp)
    print(f"  ✓  torchaudio.save() works — backend: soundfile (no torchcodec)")
    sys.exit(0)
except ImportError as e:
    if 'torchcodec' in str(e).lower():
        print(f"  ✗  torchcodec error: {e}")
        print("     torchaudio version is too new. Delete .venv/ and rerun.")
        sys.exit(1)
    raise
except Exception as e:
    print(f"  ✗  Unexpected error: {e}")
    sys.exit(1)
PYCHECK
ok "torchaudio save backend verified — soundfile (safe)"

# ════════════════════════════════════════════════════════════════════
# STEP 6 — Model weights
# ════════════════════════════════════════════════════════════════════
step 6 "Demucs model weights (htdemucs_6s, ~300 MB, downloaded once)"

python3 -c "
from demucs.pretrained import get_model
try:
    get_model('htdemucs_6s')
    print('  Weights already cached.')
except Exception as e:
    print(f'  Will auto-download on first use. ({e})')
" 2>/dev/null || warn "Model pre-check skipped — will download on first run"

# ════════════════════════════════════════════════════════════════════
# STEP 7 — Launch
# ════════════════════════════════════════════════════════════════════
step 7 "Launching Demuze"

mkdir -p "$SCRIPT_DIR/outputs" "$SCRIPT_DIR/temp"

echo ""
echo -e "  ${G}${B}✓  All steps complete. Demuze is starting…${N}"
echo ""
echo -e "  🌐  ${B}http://localhost:${PORT}${N}"
echo -e "  ${D}Ctrl+C to stop.${N}"
echo ""

(sleep 2 && {
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" &>/dev/null || true
  command -v open     &>/dev/null && open     "http://localhost:${PORT}"              || true
}) &

cd "$SCRIPT_DIR/backend"
exec uvicorn main:app --host 0.0.0.0 --port "${PORT}" --reload
