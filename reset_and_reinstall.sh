#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Demuze — Full reset helper
# Use this when something is broken and you want a clean slate.
# Equivalent to: ./install_and_run.sh --reset
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "  Demuze — Full Reset"
echo "  This will delete .venv/ and reinstall everything from scratch."
echo ""
read -r -p "  Continue? (y/N): " confirm
[[ "${confirm,,}" != "y" ]] && echo "  Cancelled." && exit 0

echo ""
echo "  Removing .venv/…"
rm -rf .venv
echo "  Done. Running installer…"
echo ""

exec ./install_and_run.sh
