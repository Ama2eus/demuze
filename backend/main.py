"""
Demuze — Offline Audio Stem Separator
FastAPI Backend v2.0

LEGAL NOTICE — FFmpeg
  This application calls the system-installed FFmpeg binary via subprocess.
  FFmpeg is NOT bundled, embedded, downloaded, or statically linked.
  The user is responsible for installing FFmpeg independently.
  Compatible with LGPL FFmpeg builds. See LEGAL.md.

LEGAL NOTICE — Demucs
  Called via CLI subprocess. Not bundled. MIT License.
  https://github.com/facebookresearch/demucs/blob/main/LICENSE
"""

import asyncio
import io
import logging
import shutil
import subprocess
import uuid
import zipfile
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR     = Path(__file__).parent.parent
TEMP_DIR     = BASE_DIR / "temp"
OUTPUT_DIR   = BASE_DIR / "outputs"
FRONTEND_DIR = BASE_DIR / "frontend"

TEMP_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

# ── Config ────────────────────────────────────────────────────────────────────
DEMUCS_MODEL       = "htdemucs_6s"
ALLOWED_EXTENSIONS = {".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac", ".opus"}
MAX_FILE_SIZE_MB   = 300

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="Demuze", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/outputs", StaticFiles(directory=str(OUTPUT_DIR)), name="outputs")
app.mount("/static",  StaticFiles(directory=str(FRONTEND_DIR / "static")), name="static")


# ── Tool verification (LEGAL: PATH lookup only, never downloads) ──────────────

def find_tool(name: str) -> Optional[str]:
    """Locate executable on system PATH. Never downloads or installs anything."""
    return shutil.which(name)


def verify_ffmpeg() -> tuple:
    """Run 'ffmpeg -version' to confirm the system FFmpeg is functional."""
    if not find_tool("ffmpeg"):
        return False, (
            "FFmpeg not found on PATH. Install from https://ffmpeg.org/download.html — "
            "this app never downloads FFmpeg automatically."
        )
    try:
        r = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return False, "FFmpeg found but '-version' failed — reinstall FFmpeg."
        first = r.stdout.splitlines()[0]
        return True, f"FFmpeg OK — {first}"
    except subprocess.TimeoutExpired:
        return False, "FFmpeg '-version' timed out."
    except Exception as e:
        return False, f"FFmpeg check error: {e}"


def verify_demucs() -> tuple:
    path = find_tool("demucs")
    if not path:
        return False, "demucs not found — run: pip install demucs"
    return True, f"Demucs OK — {path}"


# ── Subprocess helper ─────────────────────────────────────────────────────────

def run_cmd(cmd: list, cwd: Optional[Path] = None) -> tuple:
    """
    Run external command via subprocess.
    ALL external tool invocations go through here.
    No binary is ever downloaded, bundled, or embedded.
    """
    log.info("CMD: %s", " ".join(str(c) for c in cmd))
    r = subprocess.run(
        [str(c) for c in cmd],
        cwd=str(cwd) if cwd else None,
        capture_output=True, text=True,
    )
    if r.stderr:
        log.debug("STDERR: %s", r.stderr[-3000:])
    return r.returncode, r.stdout, r.stderr


# ── Audio processing ──────────────────────────────────────────────────────────

def flac_to_wav(src: Path) -> Path:
    """Convert FLAC → WAV using system FFmpeg. Workaround for torchcodec crash."""
    dst = src.with_suffix(".wav")
    rc, _, err = run_cmd(["ffmpeg", "-y", "-i", str(src), str(dst)])
    if rc != 0:
        raise RuntimeError(f"FFmpeg FLAC→WAV failed for '{src.name}': {err[-400:]}")
    src.unlink()
    return dst


def convert_stems_to_wav(stems_dir: Path) -> None:
    """Convert all FLAC stems to WAV after a Demucs --flac run."""
    flacs = list(stems_dir.glob("*.flac"))
    if not flacs:
        log.info("No FLAC stems in %s — assuming WAV", stems_dir)
        return
    log.info("Converting %d FLAC(s) → WAV via system FFmpeg", len(flacs))
    for f in flacs:
        flac_to_wav(f)


def apply_noise_gate(src: Path, dst: Path, threshold_db: float = -50.0) -> None:
    """
    Gentle noise gate + neural denoiser to reduce stem bleed artifacts.
    Uses system FFmpeg afftdn filter — not bundled.
    Falls back to plain copy if FFmpeg filter fails.
    """
    cmd = [
        "ffmpeg", "-y", "-i", str(src),
        "-af",
        f"afftdn=nr=10:nt=w,agate=threshold={threshold_db}dB:ratio=4:attack=10:release=200",
        str(dst),
    ]
    rc, _, err = run_cmd(cmd)
    if rc != 0:
        log.warning("Noise gate failed for %s (non-fatal, using clean copy): %s", src.name, err[-200:])
        shutil.copy(src, dst)


def wav_to_mp3(src: Path, dst: Path) -> None:
    """WAV → MP3 VBR q2 (~190 kbps) via system FFmpeg."""
    rc, _, err = run_cmd(["ffmpeg", "-y", "-i", str(src), "-q:a", "2", str(dst)])
    if rc != 0:
        raise RuntimeError(f"FFmpeg WAV→MP3 failed: {err[-400:]}")


def ffmpeg_mix(inputs: list, output: Path) -> None:
    """
    Mix multiple WAV stems with FFmpeg amix (no normalization).
    System FFmpeg only — not bundled, not modified.
    """
    if not inputs:
        raise ValueError("ffmpeg_mix: no inputs")
    cmd = ["ffmpeg", "-y"]
    for p in inputs:
        cmd += ["-i", str(p)]
    n = len(inputs)
    if n == 1:
        cmd += ["-c", "copy", str(output)]
    else:
        filt = "".join(f"[{i}:a]" for i in range(n))
        filt += f"amix=inputs={n}:normalize=0[aout]"
        cmd += ["-filter_complex", filt, "-map", "[aout]"]
        cmd.append(str(output))
    rc, _, err = run_cmd(cmd)
    if rc != 0:
        raise RuntimeError(f"FFmpeg mix failed: {err[-500:]}")


# ── Stem configuration ────────────────────────────────────────────────────────

STEM_CONFIGS = {
    # Pure isolations
    "drums":    ("Drums",    ["drums"]),
    "bass":     ("Bass",     ["bass"]),
    "guitar":   ("Guitar",   ["guitar"]),
    "piano":    ("Piano",    ["piano"]),
    "vocals":   ("Vocals",   ["vocals"]),
    "other":    ("Other",    ["other"]),
    # Composite mixes
    "no_drums": ("No Drums", ["bass", "guitar", "other", "piano", "vocals"]),
    "karaoke":  ("Karaoke",  ["bass", "drums", "guitar", "other", "piano"]),
}

ALL_OUTPUT_KEYS = list(STEM_CONFIGS.keys())


def build_outputs(
    stems_dir: Path,
    original_stem: str,
    requested: list,
    export_mp3: bool = False,
    use_noise_gate: bool = True,
) -> dict:
    """
    Build all requested output files from raw Demucs stems.
    Output filename convention: OriginalName_stem_isolated.ext
    All audio processing uses system FFmpeg via subprocess.
    """

    def wav(name: str) -> Path:
        p = stems_dir / f"{name}.wav"
        if not p.exists():
            available = [f.name for f in stems_dir.glob("*.wav")]
            raise FileNotFoundError(f"Stem '{name}.wav' not found. Available: {available}")
        return p

    safe_orig = "".join(c if c.isalnum() or c in "-_" else "_" for c in original_stem)
    results: dict = {}

    for key in requested:
        if key not in STEM_CONFIGS:
            log.warning("Unknown output '%s' — skipping", key)
            continue

        _, source_stems = STEM_CONFIGS[key]
        log.info("Building: %s ← [%s]", key, "+".join(source_stems))

        # Step 1: Mix stems → temp WAV
        mixed = stems_dir / f"_mix_{key}.wav"
        try:
            ffmpeg_mix([wav(s) for s in source_stems], mixed)
        except FileNotFoundError as e:
            log.error("Skipping %s: %s", key, e)
            continue

        # Step 2: Noise gate
        if use_noise_gate:
            gated = stems_dir / f"_gate_{key}.wav"
            apply_noise_gate(mixed, gated)
            mixed.unlink(missing_ok=True)
        else:
            gated = mixed

        # Step 3: Final output with clean filename
        ext = ".mp3" if export_mp3 else ".wav"
        final = stems_dir / f"{safe_orig}_{key}_isolated{ext}"

        if export_mp3:
            wav_to_mp3(gated, final)
            gated.unlink(missing_ok=True)
        else:
            gated.rename(final)

        results[key] = f"/outputs/{stems_dir.parent.name}/{stems_dir.name}/{final.name}"
        log.info("Done: %s", final.name)

    return results


def cleanup_file(path: Path) -> None:
    try:
        if path.exists():
            path.unlink()
    except Exception as e:
        log.warning("Cleanup failed %s: %s", path, e)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    idx = FRONTEND_DIR / "index.html"
    return FileResponse(str(idx)) if idx.exists() else {"status": "Demuze API running"}


@app.get("/health")
async def health():
    import sys
    issues = []
    details = {}

    vi = sys.version_info
    py_ok = (3, 10) <= (vi.major, vi.minor) <= (3, 12)
    details["python"] = f"{vi.major}.{vi.minor}.{vi.micro}"
    if not py_ok:
        issues.append(f"Python {vi.major}.{vi.minor} not supported by PyTorch. Use 3.10–3.12.")

    # torchaudio version check — 2.3+ routes .save() through torchcodec (not installed)
    # torchaudio 2.2.x is the last safe version using soundfile backend
    try:
        import torchaudio
        ta_ver = torchaudio.__version__.split("+")[0]  # strip "+cpu" suffix
        ta_parts = tuple(int(x) for x in ta_ver.split(".")[:2])
        details["torchaudio"] = f"torchaudio=={ta_ver}"
        if ta_parts >= (2, 3):
            issues.append(
                f"torchaudio=={ta_ver} detected. Version 2.3+ requires torchcodec (not installed) "
                "and will crash during separation. "
                "Fix: delete .venv/ and rerun install_and_run.sh — it will install torchaudio==2.2.2."
            )
        else:
            details["torchaudio"] += " ✓ (soundfile backend — safe)"
    except ImportError:
        issues.append("torchaudio not installed. Run the installer.")
        details["torchaudio"] = "not installed"

    ffmpeg_ok, ffmpeg_msg = verify_ffmpeg()
    details["ffmpeg"] = ffmpeg_msg
    if not ffmpeg_ok:
        issues.append(ffmpeg_msg)

    demucs_ok, demucs_msg = verify_demucs()
    details["demucs"] = demucs_msg
    if not demucs_ok:
        issues.append(demucs_msg)

    return {
        "status":   "ok" if not issues else "degraded",
        "details":  details,
        "issues":   issues,
        "outputs_available": ALL_OUTPUT_KEYS,
    }


@app.post("/separate")
async def separate(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    outputs: str = Query(default=",".join(ALL_OUTPUT_KEYS)),
    export_mp3: bool = Query(default=False),
    high_quality: bool = Query(default=False),
    noise_gate: bool = Query(default=True),
):
    """
    Accept audio upload, run Demucs, build stem outputs.
    External tools: demucs CLI + ffmpeg CLI (both via subprocess, never bundled).
    """
    ffmpeg_ok, ffmpeg_msg = verify_ffmpeg()
    if not ffmpeg_ok:
        raise HTTPException(503, f"FFmpeg unavailable: {ffmpeg_msg}")

    demucs_ok, demucs_msg = verify_demucs()
    if not demucs_ok:
        raise HTTPException(503, f"Demucs unavailable: {demucs_msg}")

    suffix = Path(file.filename or "upload").suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        raise HTTPException(400, f"Unsupported format '{suffix}'. Allowed: {sorted(ALLOWED_EXTENSIONS)}")

    requested = [o.strip() for o in outputs.split(",") if o.strip()]
    invalid = [o for o in requested if o not in STEM_CONFIGS]
    if invalid:
        raise HTTPException(400, f"Unknown output keys: {invalid}. Valid: {ALL_OUTPUT_KEYS}")

    job_id     = uuid.uuid4().hex
    temp_audio = TEMP_DIR / f"{job_id}{suffix}"
    original_stem = Path(file.filename or "audio").stem

    try:
        data = await file.read()
        size_mb = len(data) / 1_048_576
        if size_mb > MAX_FILE_SIZE_MB:
            raise HTTPException(400, f"File too large ({size_mb:.1f} MB). Max: {MAX_FILE_SIZE_MB} MB")
        temp_audio.write_bytes(data)
        log.info("Upload: %s (%.2f MB)", temp_audio.name, size_mb)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"Save failed: {e}")

    # Demucs command — --flac avoids torchaudio/torchcodec crash
    demucs_cmd = ["demucs", "--name", DEMUCS_MODEL, "--out", str(OUTPUT_DIR), "--flac"]
    if high_quality:
        demucs_cmd += ["--shifts", "5", "--overlap", "0.5"]
    demucs_cmd.append(str(temp_audio))

    loop = asyncio.get_event_loop()
    try:
        rc, _, stderr = await loop.run_in_executor(None, lambda: run_cmd(demucs_cmd))
    except Exception as e:
        background_tasks.add_task(cleanup_file, temp_audio)
        raise HTTPException(500, f"Demucs error: {e}")

    if rc != 0:
        background_tasks.add_task(cleanup_file, temp_audio)
        raise HTTPException(500, f"Demucs failed (exit {rc}): {stderr[-500:]}")

    stems_dir = OUTPUT_DIR / DEMUCS_MODEL / temp_audio.stem
    if not stems_dir.exists():
        background_tasks.add_task(cleanup_file, temp_audio)
        raise HTTPException(500, f"Stem directory not found: {stems_dir}")

    try:
        await loop.run_in_executor(None, lambda: convert_stems_to_wav(stems_dir))
    except Exception as e:
        background_tasks.add_task(cleanup_file, temp_audio)
        raise HTTPException(500, f"FLAC→WAV failed: {e}")

    try:
        url_map = await loop.run_in_executor(
            None,
            lambda: build_outputs(stems_dir, original_stem, requested, export_mp3, noise_gate),
        )
    except Exception as e:
        background_tasks.add_task(cleanup_file, temp_audio)
        raise HTTPException(500, f"Output build failed: {e}")

    background_tasks.add_task(cleanup_file, temp_audio)

    return JSONResponse({
        "job_id":            job_id,
        "original_filename": file.filename,
        "original_stem":     original_stem,
        "export_format":     "mp3" if export_mp3 else "wav",
        "high_quality":      high_quality,
        "noise_gate":        noise_gate,
        "outputs":           url_map,
    })


@app.get("/download-zip/{job_id}")
async def download_zip(job_id: str):
    """
    Stream all isolated stems for a job as a ZIP archive.
    Archive name: OriginalName.zip
    Internal files: OriginalName_stem_isolated.ext
    """
    stems_dir = OUTPUT_DIR / DEMUCS_MODEL / job_id
    if not stems_dir.exists():
        raise HTTPException(404, f"Job '{job_id}' not found")

    output_files = sorted(f for f in stems_dir.glob("*_isolated.*") if f.is_file())
    if not output_files:
        raise HTTPException(404, "No output files found for this job")

    # Derive archive name from first output file
    first_stem = output_files[0].stem  # e.g. "MySong_drums_isolated"
    parts = first_stem.rsplit("_", 2)
    archive_name = f"{parts[0]}.zip" if len(parts) >= 3 else "demuze_stems.zip"

    def stream_zip():
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for f in output_files:
                zf.write(f, arcname=f.name)
        buf.seek(0)
        while chunk := buf.read(65536):
            yield chunk

    return StreamingResponse(
        stream_zip(),
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{archive_name}"'},
    )


@app.get("/jobs/{job_id}")
async def get_job(job_id: str):
    stems_dir = OUTPUT_DIR / DEMUCS_MODEL / job_id
    if not stems_dir.exists():
        raise HTTPException(404, f"Job '{job_id}' not found")
    files = {
        p.stem: f"/outputs/{DEMUCS_MODEL}/{job_id}/{p.name}"
        for ext in ("*.wav", "*.mp3")
        for p in stems_dir.glob(ext)
        if "_isolated" in p.name
    }
    return {"job_id": job_id, "files": files}
