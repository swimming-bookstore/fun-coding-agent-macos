#!/bin/bash
# bash 3.2 (Xcode /bin/bash)
set -e
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/macos/Fun/Generated"
CORE="${FUN_GUI_CORE:-$ROOT/gui-core}"

exec "$CORE/scripts/build.sh" "$OUT"
