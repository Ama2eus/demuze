# Demuze — Offline Audio Stem Separator

> *Separate any track into its individual stems. Completely offline. Studio quality. Free forever.*

---

## ✦ What is Demuze?

Demuze is a **local, open-source audio source separation application** powered by
[Demucs htdemucs_6s](https://github.com/facebookresearch/demucs) (Meta AI Research).

Upload any audio file and get back up to **8 clean, separate outputs**:

| Output | What you get |
|---|---|
| 🎤 **Vocals** | Isolated voice(s) |
| 🥁 **Drums** | Isolated percussion / drum kit |
| 🎸 **Bass** | Isolated bass line |
| 🎵 **Guitar** | Isolated guitar |
| 🎹 **Piano** | Isolated piano / keys |
| 🎶 **Other** | Remaining instruments |
| 🔇 **No Drums** | Full mix with drums removed |
| 🎙️ **Karaoke** | Full instrumental (vocals removed) |

---

## 🌐 Is it online or offline?

**100% offline.** Always.

- All processing happens on your local machine
- No audio is ever uploaded to any server
- No account required
- No internet connection needed after first install
- No usage limits or throttling
- No subscription fees

> Your music stays on your machine. Period.

---

## ✦ Why Demuze is different

| Feature | Demuze | Moises.ai | Lalal.ai | Spleeter |
|---|---|---|---|---|
| 100% offline / private | ✅ | ❌ cloud | ❌ cloud | ✅ CLI only |
| 6-stem isolation (incl. guitar, piano) | ✅ | ❌ 4 stems | ✅ | ❌ 2 or 4 |
| Beautiful browser UI | ✅ | ✅ | ✅ | ❌ CLI only |
| Download all stems as ZIP | ✅ | Paid | Paid | ❌ |
| Free forever, unlimited tracks | ✅ | Freemium | Pay per track | ✅ |
| High-quality mode (shifted passes) | ✅ | N/A | N/A | ❌ |
| Noise gate post-processing | ✅ | N/A | N/A | ❌ |
| GPU acceleration (CUDA / Apple MPS) | ✅ | N/A | N/A | ✅ |
| Open source | ✅ | ❌ | ❌ | ✅ |

**Our tagline:** *"Studio stem separation. Your machine. Your rules."*

---

## ⚡ Quick Start

### macOS / Linux (one command)

```bash
git clone <repo-url> demuze && cd demuze
chmod +x install_and_run.sh
./install_and_run.sh
```

This script will:
1. Detect your OS
2. Install Python 3.12 if needed (via brew / apt / dnf)
3. Install FFmpeg if needed (via your OS package manager)
4. Create a Python virtual environment
5. Install all Python dependencies (~1–2 GB PyTorch + Demucs)
6. Pre-download model weights (~300 MB, one time)
7. Open Demuze in your browser at **http://localhost:8000**

### Windows (PowerShell)

```powershell
cd demuze
.\install_and_run.ps1
```

Same automatic setup — uses `winget` to install Python 3.12 and FFmpeg if needed.

### Manual start (after first install)

```bash
# Activate your virtualenv first:
source .venv/bin/activate          # Linux/macOS
.\.venv\Scripts\Activate.ps1      # Windows

cd backend
uvicorn main:app --port 8000 --reload
```

---

## 🎛️ Features

### Stem Selection
Choose exactly which outputs you want. Toggle individual stems on/off before processing.
"Select All" and "Clear" buttons for quick selection.

### High Quality Mode
Enables `--shifts 5 --overlap 0.5` in Demucs:
- Runs 5 shifted predictions and averages them
- Significantly reduces artifacts and stem bleed
- 3–5× slower than standard mode
- Recommended for final, export-quality work

### Noise Gate
Applies FFmpeg's `afftdn` neural denoiser + `agate` filter after mixing.
Reduces the quiet bleed from other stems (e.g. slight voice in the piano stem).
Default: **on**.

### MP3 Export
Toggle between lossless WAV (default) and VBR MP3 (~190 kbps, ~5× smaller).

### Download All as ZIP
One click downloads all your stems as a single ZIP file.

**Output naming convention:**
- Individual: `MySong_vocals_isolated.wav`
- ZIP archive: `MySong.zip`
- Inside ZIP: `MySong_drums_isolated.wav`, `MySong_bass_isolated.wav`, etc.

---

## 🔊 Audio Quality

### Why you hear some bleed
Source separation is a statistical estimation problem. The model cannot achieve
perfect isolation — some low-level bleed from other instruments is inherent to the
technique. This affects all current AI separation tools.

### How Demuze minimizes it

1. **htdemucs_6s model** — Meta's latest 6-stem model, trained on a large diverse dataset
2. **High Quality mode** — Multiple shifted predictions averaged → significantly cleaner
3. **Noise gate** — FFmpeg `afftdn` denoiser + `agate` suppress residual bleed below threshold
4. **FLAC intermediate** — Lossless intermediate format preserves quality through processing

### Tips for best results
- Enable **High Quality mode** for final exports
- Use WAV output for the cleanest result
- For vocals: songs with clear vocal separation (not heavily doubled/layered) work best
- For instruments: stems work better on tracks where that instrument is prominent

---

## ⚖️ Legal Notices

### FFmpeg

> **This application uses FFmpeg as an external system tool.**
> FFmpeg is **not** bundled, embedded, downloaded by the app, or statically linked.
> FFmpeg is called via `subprocess` using the system PATH.
> The user is responsible for installing FFmpeg on their own system.
>
> FFmpeg is licensed under **LGPL v2.1+**.
> This application is designed for and tested with standard LGPL builds.
> See [LEGAL.md](LEGAL.md) · [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html)

### Demucs

> Demucs is called via its CLI. Not bundled. **MIT License.**
> © Meta Platforms, Inc.
> [github.com/facebookresearch/demucs](https://github.com/facebookresearch/demucs/blob/main/LICENSE)

### Demuze

> **MIT License.** Free for personal and commercial use.
> Because FFmpeg is called as an external process (not linked/embedded),
> Demuze's MIT license is not encumbered by FFmpeg's LGPL terms.

---

## 💰 Support & Monetization

Demuze is free and open source. Ways to sustain it:

- ⭐ **Star the repo** — helps with discoverability
- ☕ **Ko-fi / GitHub Sponsors** — direct tip from grateful users
- 🎵 **Content creators** — mention Demuze when you use it for remixes / covers
- 🔧 **Pro version** (roadmap) — batch processing, preset chains, BPM/key export
- 📹 **YouTube** — tutorials on stem separation, remixing with Demuze

---

## 🛠️ Configuration

Edit `backend/main.py`:

```python
DEMUCS_MODEL     = "htdemucs_6s"   # model to use
MAX_FILE_SIZE_MB = 300              # upload size limit
```

Custom port:
```bash
PORT=8080 ./install_and_run.sh
.\install_and_run.ps1 -Port 8080
```

---

## 📋 System Requirements

| Component | Minimum | Recommended |
|---|---|---|
| Python | 3.10 | 3.12 |
| RAM | 8 GB | 16 GB |
| Disk | 5 GB (PyTorch + models) | 10 GB |
| GPU | None (CPU works) | CUDA GPU or Apple M-series |
| FFmpeg | Any LGPL build | Latest stable |

Processing time per 3-minute track:
- CPU only: ~5–15 min (standard) / ~25–60 min (HQ)
- NVIDIA GPU: ~30–90 sec (standard) / ~3–8 min (HQ)
- Apple M-series: ~1–3 min (standard) / ~5–15 min (HQ)

---

## 🐛 Troubleshooting

**"FFmpeg not found"** — Install from [ffmpeg.org](https://ffmpeg.org/download.html). The app never installs it automatically.

**"Python 3.13/3.14 not supported"** — PyTorch requires 3.10–3.12. Delete `.venv/` and rerun the installer with `python3.12`.

**"torchcodec / torchaudio error"** — Already handled: we pass `--flac` to Demucs and convert via FFmpeg.

**Stems have noticeable bleed** — Enable High Quality mode and Noise Gate. These are default tradeoffs of neural separation.

**Very slow processing** — Normal on CPU. Check GPU: `python -c "import torch; print(torch.cuda.is_available())"` (or `torch.backends.mps.is_available()` on Mac).

---

## Project Structure

```
demuze/
├── backend/
│   ├── main.py              # FastAPI app — all backend logic
│   └── requirements.txt     # Python dependencies
├── frontend/
│   └── index.html           # Single-page UI — no build step
├── outputs/                 # Demucs outputs (auto-created)
├── temp/                    # Temp uploads (auto-cleaned)
├── install_and_run.sh       # macOS/Linux smart installer + launcher
├── install_and_run.ps1      # Windows smart installer + launcher
├── LEGAL.md                 # Full licensing details
├── LICENSE                  # MIT License
└── README.md
```
