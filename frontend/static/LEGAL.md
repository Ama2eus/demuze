# Legal Notices — Demuze

## FFmpeg

| Statement | Detail |
|---|---|
| Bundled with Demuze? | **No** |
| Embedded binary? | **No** |
| Statically linked? | **No** |
| Source modified? | **No** |
| Auto-downloaded by app? | **No** |
| Installed by installer script? | **Via OS package manager only** (brew/apt/dnf/winget) |
| User responsibility? | **Yes — user must have FFmpeg installed** |

**How FFmpeg is used:**
`subprocess.run(["ffmpeg", ...])` — calls the system binary on PATH.
Used for: FLAC→WAV conversion, noise gate filter, stem mixing, MP3 export.

**FFmpeg License:** LGPL v2.1+ · https://ffmpeg.org/legal.html

---

## Demucs

Called via `subprocess.run(["demucs", ...])`. Not bundled.
**MIT License** · Copyright © Meta Platforms, Inc.
https://github.com/facebookresearch/demucs/blob/main/LICENSE

---

## PyTorch / torchaudio

Installed as Python packages. **BSD License.**

---

## Demuze

**MIT License** — see LICENSE file.
FFmpeg's LGPL does not encumber Demuze because FFmpeg is an external process,
not linked or embedded. Distributors: do not bundle FFmpeg binaries.
