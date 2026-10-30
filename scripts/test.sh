#!/usr/bin/env bash
# Run the offline test suite with LuaJIT (same engine as Renoise 3.5).
set -euo pipefail
cd "$(dirname "$0")/.."
exec luajit tests/run.lua "$@"
