#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Demuze — Installer & Launcher  (macOS / Linux)
#  v2.4 — merged stable patch
#
#  Usage:
#    ./install_and_run.sh            normal run (reuses .venv if it exists)
#    ./install_and_run.sh --reset    wipe .venv and reinstall from scratch
#    PORT=8080 ./install_and_run.sh  use a different port
#
#  Key decisions:
#    • torch 2.2.2 + torchaudio 2.2.2  — last versions using soundfile backend
#    • numpy < 2                        — required by torch 2.2.x C-ABI
#    • CPU-only PyTorch by default      — safe for all machines (~180 MB)
#    • MAX_JOBS=1 / OMP_NUM_THREADS=1   — prevents RAM spike during install
#    • Packages installed one at a time — numpy → torch → rest → demucs
#    • numpy re-pinned after demucs     — demucs deps can upgrade it
#    • Version check uses prefix match  — handles "2.2.2+cpu" correctly
#
#  LEGAL: FFmpeg is never bundled. Installed via OS package manager only.
#         See LEGAL.md for full details.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PORT="${PORT:-8000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Parse flags ───────────────────────────────────────────────────────────────
RESET=false
for arg in "$@"; do
  [[ "$arg" == "--reset" ]] && RESET=true
done

# ── Pinned versions ───────────────────────────────────────────────────────────
TORCH_VERSION="2.2.2"
TORCHAUDIO_VERSION="2.2.2"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' C='\033[0;36m' B='\033[1m' D='\033[2m' N='\033[0m'
ok()   { echo -e "  ${G}✓${N}  $*"; }
warn() { echo -e "  ${Y}⚠${N}  $*"; }
err()  { echo -e "  ${R}✗${N}  $*"; exit 1; }
info() { echo -e "  ${C}→${N}  $*"; }
step() { echo -e "\n${B}  [$1/7] $2${N}\n  ${D}────────────────────────────────────────${N}"; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${B}  DEMUZE — Offline Audio Stem Separator${N}"
echo -e "  ${C}Powered by Demucs htdemucs_6s · 100% Offline · MIT License${N}"
echo -e "  ${D}torch==${TORCH_VERSION}  torchaudio==${TORCHAUDIO_VERSION}  numpy<2${N}"
$RESET && echo -e "  ${Y}--reset flag detected: .venv will be wiped${N}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
# Strip the +cpu / +cu121 local label pip appends to wheel versions.
# "2.2.2+cpu" → "2.2.2"
strip_local() { echo "${1%%+*}"; }

# Get the base version of an installed package, or "none".
get_base_ver() {
  local raw
  raw=$(pip show "$1" 2>/dev/null | awk '/^Version:/{print $2}')
  [[ -z "$raw" ]] && echo "none" || strip_local "$raw"
}

# ════════════════════════════════════════════════════════════════════
# STEP 1 — System diagnostics
# ════════════════════════════════════════════════════════════════════
step 1 "System diagnostics"

OS="unknown"
if   [[ "$OSTYPE" == "darwin"* ]];                              then OS="macos";  ok "macOS"
elif [[ -f /etc/debian_version ]];                              then OS="debian"; ok "Debian / Ubuntu"
elif [[ -f /etc/fedora-release || -f /etc/redhat-release ]];   then OS="fedora"; ok "Fedora / RHEL"
elif [[ -f /etc/arch-release ]];                               then OS="arch";   ok "Arch Linux"
else warn "Unknown OS — package auto-install skipped"; fi

# RAM
RAM_MB=0
if   [[ "$OS" == "macos" ]]; then
  RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
elif command -v free &>/dev/null; then
  RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
fi

if   [[ $RAM_MB -ge 16000 ]]; then ok "RAM: ${RAM_MB} MB"
elif [[ $RAM_MB -ge  8000 ]]; then ok "RAM: ${RAM_MB} MB — adequate"
elif [[ $RAM_MB -ge  4000 ]]; then warn "RAM: ${RAM_MB} MB — limited, CPU-only PyTorch enforced"
elif [[ $RAM_MB -gt     0 ]]; then warn "RAM: ${RAM_MB} MB — very low, CPU-only PyTorch enforced"
else                                warn "RAM unknown — CPU-only PyTorch (safe default)"; fi

# GPU / torch index
TORCH_INDEX="https://download.pytorch.org/whl/cpu"
TORCH_VARIANT="cpu"

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
  ok "NVIDIA GPU: $GPU_NAME"
  if [[ $RAM_MB -ge 8000 || $RAM_MB -eq 0 ]]; then
    echo ""
    echo -e "  ${B}PyTorch variant:${N}"
    echo "    [1] CPU-only  ~180 MB   safe, always works  (default, press Enter)"
    echo "    [2] CUDA GPU  ~2.4 GB   5-15x faster"
    echo ""
    read -r -t 20 -p "  Choice (1/2, auto-selects CPU in 20s): " GPU_CHOICE </dev/tty || GPU_CHOICE="1"
    if [[ "${GPU_CHOICE:-1}" == "2" ]]; then
      CUDA_MAJ=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K\d+' || echo "12")
      [[ "$CUDA_MAJ" -ge 12 ]] \
        && TORCH_INDEX="https://download.pytorch.org/whl/cu121" \
        || TORCH_INDEX="https://download.pytorch.org/whl/cu118"
      TORCH_VARIANT="cuda"
      ok "CUDA selected — index: $TORCH_INDEX"
    else
      ok "CPU selected"
    fi
  else
    warn "Low RAM — CPU PyTorch enforced"
  fi
elif [[ "$OS" == "macos" && "$(uname -m 2>/dev/null)" == "arm64" ]]; then
  ok "Apple Silicon — MPS acceleration included in macOS torch"
else
  ok "CPU PyTorch (works on all hardware)"
fi

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
      PY_CMD="$c"; ok "$c  (Python $v)"; break
    fi
  fi
done

if [[ -z "$PY_CMD" ]]; then
  warn "No compatible Python found — attempting auto-install…"
  case "$OS" in
    macos)
      command -v brew &>/dev/null \
        && { brew install python@3.12; PY_CMD="python3.12"; } \
        || err "Install Homebrew (https://brew.sh) first, then rerun." ;;
    debian)
      sudo apt-get update -qq
      sudo apt-get install -y python3.12 python3.12-venv python3.12-dev
      PY_CMD="python3.12" ;;
    fedora)
      sudo dnf install -y python3.12 python3.12-devel
      PY_CMD="python3.12" ;;
    arch)
      sudo pacman -S --noconfirm python python-pip
      PY_CMD="python" ;;
    *)
      echo "  Install Python 3.12: https://www.python.org/downloads"
      echo "  Python 3.13/3.14 are NOT supported by PyTorch."
      err "Cannot auto-install Python on this OS." ;;
  esac
  ok "Python installed: $PY_CMD"
fi

"$PY_CMD" -m pip --version &>/dev/null || "$PY_CMD" -m ensurepip --upgrade 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════
# STEP 3 — FFmpeg  (LEGAL: PATH check + OS package manager only)
# This application never downloads or bundles FFmpeg binaries.
# FFmpeg is installed via the user's OS package manager.
# See LEGAL.md — compatible with LGPL FFmpeg builds.
# ════════════════════════════════════════════════════════════════════
step 3 "FFmpeg — external LGPL dependency"

if command -v ffmpeg &>/dev/null && ffmpeg -version &>/dev/null 2>&1; then
  ok "$(ffmpeg -version 2>&1 | head -1)"
else
  warn "FFmpeg not found — installing via OS package manager (LGPL build)…"
  case "$OS" in
    macos)
      command -v brew &>/dev/null \
        && brew install ffmpeg \
        || err "Install Homebrew first (https://brew.sh), then rerun." ;;
    debian)
      sudo apt-get update -qq && sudo apt-get install -y ffmpeg ;;
    fedora)
      rpm -q rpmfusion-free-release &>/dev/null || \
        sudo dnf install -y \
          "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
          2>/dev/null || true
      sudo dnf install -y ffmpeg ;;
    arch)
      sudo pacman -S --noconfirm ffmpeg ;;
    *)
      err "Cannot auto-install FFmpeg. Install from https://ffmpeg.org/download.html then rerun." ;;
  esac
  ffmpeg -version &>/dev/null 2>&1 \
    && ok "FFmpeg installed" \
    || err "FFmpeg install failed — install manually from https://ffmpeg.org/download.html"
fi

# ════════════════════════════════════════════════════════════════════
# STEP 4 — Virtual environment
# ════════════════════════════════════════════════════════════════════
step 4 "Python virtual environment"

VENV="$SCRIPT_DIR/.venv"

if $RESET && [[ -d "$VENV" ]]; then
  warn "Wiping existing .venv (--reset)…"
  rm -rf "$VENV"
  ok "Removed"
fi

if [[ ! -d "$VENV" ]]; then
  info "Creating .venv with $PY_CMD …"
  "$PY_CMD" -m venv "$VENV"
  ok "Created"
else
  ok "Reusing existing .venv"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

# ════════════════════════════════════════════════════════════════════
# STEP 5 — Package installation (RAM-safe, sequential, pinned)
#
#  Install order matters:
#    1. pip upgrade          — always first
#    2. numpy < 2            — BEFORE torch (prevents ABI conflict)
#    3. torch + torchaudio   — alone, one at a time (largest packages)
#    4. fastapi + uvicorn    — web stack
#    5. soundfile            — torchaudio save backend
#    6. demucs               — after torch so it reuses the pinned wheel
#    7. numpy < 2 again      — demucs deps may upgrade numpy; re-enforce
#
#  RAM safety:
#    MAX_JOBS=1 / OMP_NUM_THREADS=1 etc. prevent parallel build workers.
#    --no-cache-dir avoids double-buffering the wheel in RAM and on disk.
#    CPU torch by default: ~180 MB vs ~2.4 GB for CUDA.
#
#  Version check:
#    pip show returns "2.2.2+cpu" on Linux.
#    We use prefix match (strip_local / get_base_ver) not exact string match.
# ════════════════════════════════════════════════════════════════════
step 5 "Installing Python packages (pinned, RAM-safe)"

export MAX_JOBS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

# 5-1. pip
info "Upgrading pip…"
pip install --quiet --upgrade pip

# 5-2. numpy < 2  (MUST come before torch)
info "Installing numpy < 2 (required by torch 2.2.x C-ABI)…"
pip install --no-cache-dir "numpy>=1.24,<2"
ok "numpy $(get_base_ver numpy)"

# 5-3. torch + torchaudio — check first, install only if needed
CUR_T=$(get_base_ver torch)
CUR_TA=$(get_base_ver torchaudio)

if [[ "$CUR_T" == "$TORCH_VERSION" && "$CUR_TA" == "$TORCHAUDIO_VERSION" ]]; then
  ok "torch==$CUR_T + torchaudio==$CUR_TA already installed"
else
  # Remove mismatched versions before installing pinned ones
  if [[ "$CUR_TA" != "none" && "$CUR_TA" != "$TORCHAUDIO_VERSION" ]]; then
    warn "Removing incompatible torchaudio==$CUR_TA (2.3+ requires torchcodec → crash)…"
    pip uninstall -y torchaudio torch 2>/dev/null || true
  fi

  if [[ "$TORCH_VARIANT" == "cuda" ]]; then
    info "Installing torch==${TORCH_VERSION} + torchaudio==${TORCHAUDIO_VERSION} CUDA (~2.4 GB)…"
    warn "Large download — do not close this window."
  else
    info "Installing torch==${TORCH_VERSION} + torchaudio==${TORCHAUDIO_VERSION} CPU (~180 MB)…"
  fi

  pip install --no-cache-dir \
    "torch==${TORCH_VERSION}" \
    "torchaudio==${TORCHAUDIO_VERSION}" \
    --index-url "$TORCH_INDEX"
  ok "torch + torchaudio installed"
fi

# 5-3. Verify — prefix match handles "2.2.2+cpu" correctly
FINAL_TA=$(get_base_ver torchaudio)
if [[ "$FINAL_TA" != "$TORCHAUDIO_VERSION" ]]; then
  err "torchaudio version mismatch: got '$FINAL_TA', need '$TORCHAUDIO_VERSION'.
       Run:  rm -rf .venv && ./install_and_run.sh --reset"
fi
ok "torchaudio==$FINAL_TA — soundfile backend (no torchcodec needed)"

# 5-4. FastAPI + Uvicorn
info "Installing FastAPI + Uvicorn…"
pip install --no-cache-dir \
  "fastapi>=0.111.0" \
  "uvicorn[standard]>=0.29.0" \
  "python-multipart>=0.0.9"
ok "FastAPI + Uvicorn"

# 5-5. soundfile
info "Installing soundfile…"
pip install --no-cache-dir "soundfile>=0.12.1"
ok "soundfile"

# 5-6. Demucs
info "Installing Demucs (~150 MB)…"
pip install --no-cache-dir "demucs>=4.0.1"
ok "Demucs"

# 5-7. Re-enforce numpy < 2 — demucs transitive deps may have upgraded it
NUMPY_NOW=$(get_base_ver numpy)
if [[ "${NUMPY_NOW%%.*}" -ge 2 ]] 2>/dev/null; then
  warn "numpy was upgraded to $NUMPY_NOW by a dependency — re-pinning to <2…"
  pip install --no-cache-dir "numpy>=1.24,<2"
  ok "numpy re-pinned to $(get_base_ver numpy)"
else
  ok "numpy $NUMPY_NOW — compatible (< 2)"
fi

# 5-8. Sanity checks
command -v demucs  &>/dev/null || err "demucs not found — check pip output above"
command -v uvicorn &>/dev/null || err "uvicorn not found — check pip output above"

# 5-9. Functional test
# stderr redirected to /dev/null to suppress the harmless NumPy 1.x ABI warning
# ("A module compiled using NumPy 1.x cannot be run in NumPy 2.x")
# which C extensions print even when everything works correctly.
info "Functional test: torch import + torchaudio.save()…"
TEST=$(python3 2>/dev/null << 'PYCHECK'
import sys, os, tempfile, warnings
warnings.filterwarnings("ignore")
try:
    import torch
except Exception as e:
    print(f"FAIL_TORCH:{e}"); sys.exit(1)
try:
    import torchaudio
    t = torch.zeros(2, 16000)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        p = f.name
    torchaudio.save(p, t, 16000)
    os.unlink(p)
    print(f"OK torch={torch.__version__} torchaudio={torchaudio.__version__}")
    sys.exit(0)
except ImportError as e:
    msg = str(e)
    if "torchcodec" in msg.lower():
        print(f"FAIL_CODEC:{msg}")
    else:
        print(f"FAIL_IMPORT:{msg}")
    sys.exit(1)
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(1)
PYCHECK
)

if [[ "$TEST" == OK* ]]; then
  ok "Test passed — $TEST"
else
  err "Functional test failed: $TEST
       Fix: ./install_and_run.sh --reset"
fi

# ════════════════════════════════════════════════════════════════════
# STEP 6 — Model weights (~300 MB, downloaded once, cached)
# ════════════════════════════════════════════════════════════════════
step 6 "Demucs model weights (htdemucs_6s, ~300 MB — once)"

python3 2>/dev/null -c "
from demucs.pretrained import get_model
try:
    get_model('htdemucs_6s')
    print('  Weights cached.')
except Exception as e:
    print(f'  Will download on first run: {e}')
" || warn "Model pre-check skipped — weights download automatically on first use."

# ════════════════════════════════════════════════════════════════════
# STEP 7 — Launch
# ════════════════════════════════════════════════════════════════════
step 7 "Launching Demuze"

mkdir -p "$SCRIPT_DIR/outputs" "$SCRIPT_DIR/temp"

echo ""
echo -e "  ${G}${B}✓  Ready.${N}"
echo ""
echo -e "  🌐  ${B}http://localhost:${PORT}${N}"
echo -e "  ${D}Ctrl+C to stop.  Run with --reset to wipe and reinstall.${N}"
echo ""

(sleep 2 && {
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" &>/dev/null || true
  command -v open     &>/dev/null && open     "http://localhost:${PORT}"              || true
}) &

cd "$SCRIPT_DIR/backend"
exec uvicorn main:app --host 0.0.0.0 --port "${PORT}" --reload
