# ═══════════════════════════════════════════════════════════════════════════════
#  Demuze — Smart Installer & Launcher (Windows)
#  v2.2 — Pinned torch==2.2.2 / torchaudio==2.2.2 to fix torchcodec crash
#
#  ROOT CAUSE OF CRASH:
#    torchaudio 2.3+ routes ALL audio saving through torchcodec.
#    torchcodec is NOT installed with demucs.
#    Result: "ImportError: TorchCodec is required for save_with_torchcodec"
#
#  FIX: Force torch==2.2.2 + torchaudio==2.2.2 (last soundfile-backend version)
#       Uninstall any newer torchaudio that pip may have auto-upgraded to.
#       All installs: MAX_JOBS=1 OMP_NUM_THREADS=1 to prevent RAM crash.
#
#  LEGAL: FFmpeg installed via winget only — never bundled by Demuze.
# ═══════════════════════════════════════════════════════════════════════════════
param([int]$Port = 8000)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
$ErrorActionPreference = "Stop"
$TOTAL = 7

# Pinned versions
$TORCH_VERSION     = "2.2.2"
$TORCHAUDIO_VERSION = "2.2.2"

function OK($m)   { Write-Host "  [OK]  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!!]  $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "  -->   $m" -ForegroundColor Cyan }
function Step($n, $t) {
    Write-Host "`n  [$n/$TOTAL] $t" -ForegroundColor White -BackgroundColor DarkGray
    Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
}
function Bail($m) {
    Write-Host "  [ERR] $m" -ForegroundColor Red
    Read-Host "`nPress Enter to exit"
    exit 1
}

Clear-Host
Write-Host ""
Write-Host "  DEMUZE — Offline Audio Stem Separator  v2.0" -ForegroundColor Cyan
Write-Host "  torch==$TORCH_VERSION  torchaudio==$TORCHAUDIO_VERSION  (pinned - soundfile backend)"
Write-Host ""

# ════════════════════════════════════════════════════════════════════
# STEP 1 — System diagnostics
# ════════════════════════════════════════════════════════════════════
Step 1 "System diagnostics"

$ramMB = 0
try { $ramMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) } catch {}

if     ($ramMB -ge 16000) { OK  "RAM: ${ramMB} MB" }
elseif ($ramMB -ge  8000) { OK  "RAM: ${ramMB} MB — adequate" }
elseif ($ramMB -ge  4000) { Warn "RAM: ${ramMB} MB — limited, using CPU-only PyTorch" }
elseif ($ramMB -gt     0) { Warn "RAM: ${ramMB} MB — very low, using CPU-only PyTorch" }
else                       { Warn "RAM unknown — CPU-only PyTorch (safe default)" }

$torchIndex   = "https://download.pytorch.org/whl/cpu"
$torchVariant = "cpu"
$nvidiaFound  = $false

try {
    $gpuInfo = nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
    if ($LASTEXITCODE -eq 0 -and $gpuInfo) { $nvidiaFound = $true; OK "NVIDIA GPU: $gpuInfo" }
} catch {}

if ($nvidiaFound -and $ramMB -ge 8000) {
    Write-Host ""
    Write-Host "  PyTorch variant (torch==$TORCH_VERSION):" -ForegroundColor White
    Write-Host "    [1] CPU-only  ~180 MB   safe, always works   (default)"
    Write-Host "    [2] CUDA GPU  ~2.4 GB   5-15x faster"
    Write-Host ""
    $choice = Read-Host "  Choice (1/2, default=1)"
    if ($choice -eq "2") {
        $cudaLine = nvidia-smi 2>&1 | Select-String "CUDA Version"
        $cudaMaj  = if ($cudaLine -match "(\d+)\.\d+") { [int]$Matches[1] } else { 12 }
        $torchIndex   = if ($cudaMaj -ge 12) { "https://download.pytorch.org/whl/cu121" } `
                        else                 { "https://download.pytorch.org/whl/cu118" }
        $torchVariant = "cuda"
        OK "CUDA PyTorch selected"
    } else { OK "CPU PyTorch selected" }
} elseif ($nvidiaFound) { Warn "Low RAM — forcing CPU PyTorch" }
else { OK "CPU PyTorch (works for all hardware)" }

# ════════════════════════════════════════════════════════════════════
# STEP 2 — Python 3.10–3.12
# ════════════════════════════════════════════════════════════════════
Step 2 "Python runtime (3.10–3.12 required by PyTorch)"

$pyCmd = $null
foreach ($c in @("py -3.12","py -3.11","py -3.10","python3.12","python3.11","python3.10","python3","python")) {
    try {
        $parts = $c.Split(" ")
        $exe   = $parts[0]
        $pre   = if ($parts.Count -gt 1) { $parts[1..($parts.Count-1)] } else { @() }
        $ver   = & $exe @pre -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}')" 2>$null
        if ($LASTEXITCODE -eq 0 -and $ver -match "^3\.(10|11|12)$") { $pyCmd = $c; OK "Found: $c (Python $ver)"; break }
    } catch {}
}

if (-not $pyCmd) {
    Warn "No compatible Python — trying winget…"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Python.Python.3.12 --silent --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path","User")
        $pyCmd = "py -3.12"
        OK "Python 3.12 installed"
    } else { Bail "winget not available.`n  Install Python 3.12 from https://python.org/downloads`n  Python 3.13/3.14 are NOT supported by PyTorch." }
}

# ════════════════════════════════════════════════════════════════════
# STEP 3 — FFmpeg  (LEGAL: winget only, never bundled)
# ════════════════════════════════════════════════════════════════════
Step 3 "FFmpeg — external LGPL tool (installed via winget)"

$ffOk = $false
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    try {
        $ffv = (ffmpeg -version 2>&1 | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0) { OK "FFmpeg: $ffv"; $ffOk = $true }
    } catch {}
}

if (-not $ffOk) {
    Warn "FFmpeg not found — installing via winget (Gyan LGPL build)…"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Gyan.FFmpeg --silent --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path","User")
        if (Get-Command ffmpeg -ErrorAction SilentlyContinue) { OK "FFmpeg installed"; $ffOk = $true }
    }
    if (-not $ffOk) {
        Bail "FFmpeg install failed.`n  Download from https://www.gyan.dev/ffmpeg/builds/ (essentials — LGPL)`n  Add bin\ to PATH then rerun."
    }
}

# ════════════════════════════════════════════════════════════════════
# STEP 4 — Virtual environment
# ════════════════════════════════════════════════════════════════════
Step 4 "Python virtual environment"

$venvDir  = Join-Path $ScriptDir ".venv"
$activate = Join-Path $venvDir "Scripts\Activate.ps1"

if (-not (Test-Path $venvDir)) {
    Info "Creating .venv/ …"
    $pp = $pyCmd.Split(" ")
    & $pp[0] @($pp[1..($pp.Count-1)]) -m venv $venvDir
    OK "Virtualenv created"
} else { OK "Virtualenv exists" }

try { & $activate }
catch {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
    & $activate
}

# ════════════════════════════════════════════════════════════════════
# STEP 5 — RAM-safe pinned package installation
# ════════════════════════════════════════════════════════════════════
Step 5 "Installing packages (pinned versions, RAM-safe)"

$env:MAX_JOBS               = "1"
$env:OMP_NUM_THREADS        = "1"
$env:MKL_NUM_THREADS        = "1"
$env:OPENBLAS_NUM_THREADS   = "1"
$env:VECLIB_MAXIMUM_THREADS = "1"
$env:NUMEXPR_NUM_THREADS    = "1"

Info "Upgrading pip…"
pip install --quiet --upgrade pip

# ── Force-remove incompatible torchaudio ──────────────────────────────────────
Info "Checking for incompatible torchaudio (2.3+ causes torchcodec crash)…"
$installedTA = pip show torchaudio 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version: ","" }
if ($installedTA -and $installedTA -ne $TORCHAUDIO_VERSION) {
    Warn "Found torchaudio==$installedTA — removing (causes torchcodec crash)…"
    pip uninstall -y torchaudio torch 2>$null
    OK "Removed incompatible torch/torchaudio"
}

# ── Install pinned torch + torchaudio ─────────────────────────────────────────
$installedT  = pip show torch     2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version: ","" }
$installedTA = pip show torchaudio 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version: ","" }

if ($installedT -eq $TORCH_VERSION -and $installedTA -eq $TORCHAUDIO_VERSION) {
    OK "torch==$TORCH_VERSION + torchaudio==$TORCHAUDIO_VERSION already installed"
} else {
    if ($torchVariant -eq "cuda") {
        Info "Installing torch==$TORCH_VERSION CUDA (~2.4 GB) — please wait, do not close…"
    } else {
        Info "Installing torch==$TORCH_VERSION CPU-only (~180 MB)…"
    }
    pip install --no-cache-dir "torch==$TORCH_VERSION" "torchaudio==$TORCHAUDIO_VERSION" --index-url $torchIndex
    OK "torch==$TORCH_VERSION + torchaudio==$TORCHAUDIO_VERSION installed"
}

# ── Verify version is correct ─────────────────────────────────────────────────
$actualTA = pip show torchaudio 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version: ","" }
if ($actualTA -ne $TORCHAUDIO_VERSION) {
    Bail "torchaudio version mismatch: got $actualTA, need $TORCHAUDIO_VERSION`n  Delete .venv\ and rerun."
}
OK "torchaudio==$actualTA verified (soundfile backend — no torchcodec needed)"

Info "Installing FastAPI + Uvicorn…"
pip install --no-cache-dir "fastapi>=0.111.0" "uvicorn[standard]>=0.29.0" "python-multipart>=0.0.9"
OK "FastAPI installed"

Info "Installing soundfile…"
pip install --no-cache-dir "soundfile>=0.12.1"
OK "soundfile installed"

Info "Installing Demucs…"
pip install --no-cache-dir "demucs>=4.0.1"
OK "Demucs installed"

if (-not (Get-Command demucs  -ErrorAction SilentlyContinue)) { Bail "demucs not found" }
if (-not (Get-Command uvicorn -ErrorAction SilentlyContinue)) { Bail "uvicorn not found" }

# ── Functional test: torchaudio.save() without torchcodec ─────────────────────
Info "Verifying torchaudio.save() uses soundfile (not torchcodec)…"
$testResult = python -c @"
import sys, tempfile, os
try:
    import torch, torchaudio
    wav = torch.zeros(2, 16000)
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        tmp = f.name
    torchaudio.save(tmp, wav, 16000)
    os.unlink(tmp)
    print('OK soundfile backend works')
    sys.exit(0)
except ImportError as e:
    if 'torchcodec' in str(e).lower():
        print(f'FAIL torchcodec: {e}')
        sys.exit(1)
    raise
"@ 2>&1
if ($LASTEXITCODE -ne 0) {
    Bail "torchaudio.save() still broken: $testResult`n  Delete .venv\ and rerun."
}
OK "torchaudio.save() verified — soundfile backend (safe)"

# ════════════════════════════════════════════════════════════════════
# STEP 6 — Model weights
# ════════════════════════════════════════════════════════════════════
Step 6 "Demucs model weights (htdemucs_6s, ~300 MB, once)"

python -c @"
from demucs.pretrained import get_model
try:
    get_model('htdemucs_6s')
    print('  Weights cached.')
except Exception as e:
    print(f'  Will download on first use. ({e})')
"@ 2>$null

# ════════════════════════════════════════════════════════════════════
# STEP 7 — Launch
# ════════════════════════════════════════════════════════════════════
Step 7 "Launching Demuze"

New-Item -ItemType Directory -Force -Path (Join-Path $ScriptDir "outputs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ScriptDir "temp")    | Out-Null

$url = "http://localhost:$Port"
Write-Host "`n  Ready!  $url" -ForegroundColor Green
Write-Host "  Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""
Start-Process $url

Set-Location (Join-Path $ScriptDir "backend")
uvicorn main:app --host 0.0.0.0 --port $Port --reload
