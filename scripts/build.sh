#!/usr/bin/env bash
# Syntax-check every Lua file, then zip the tool into dist/<Id>.xrnx.
# Drag the .xrnx onto Renoise to install it.
set -euo pipefail
cd "$(dirname "$0")/.."
ID=com.jussisnupps.JussiSnupps
SRC="src/$ID.xrnx"
find "$SRC" tests -name '*.lua' -print0 | while IFS= read -r -d '' f; do
  luajit -bl "$f" >/dev/null || { echo "syntax error in $f"; exit 1; }
done
mkdir -p dist
rm -f "dist/$ID.xrnx"
(cd "$SRC" && zip -qr -X "../../dist/$ID.xrnx" . -x '*.json' -x '.*')
echo "built dist/$ID.xrnx"
