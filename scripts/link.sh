#!/usr/bin/env bash
# Symlink the tool source into Renoise's Tools folder for live development
# (only useful on a machine where Renoise is installed).
set -euo pipefail
cd "$(dirname "$0")/.."
ID=com.jussisnupps.JussiSnupps
TOOLS=$(ls -d "$HOME"/.renoise/V3.5*/Scripts/Tools 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$TOOLS" ]; then
  echo "No ~/.renoise/V3.5*/Scripts/Tools folder found. Start Renoise 3.5 once, or pass the path:"
  echo "  scripts/link.sh /path/to/Scripts/Tools"
  TOOLS=${1:-}
  [ -n "$TOOLS" ] || exit 1
fi
ln -sfn "$PWD/src/$ID.xrnx" "$TOOLS/$ID.xrnx"
echo "linked into $TOOLS (use Tools > Reload All Tools in Renoise)"
