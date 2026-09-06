#!/bin/bash
# bash 3.2 (Xcode /bin/bash)
set -e
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/macos/Fun/Generated"
REPO="https://github.com/swimming-bookstore/fun-coding-agent-gui-core"

if [ -n "${FUN_GUI_CORE-}" ]; then
  CORE="$FUN_GUI_CORE"
else
  CORE="$ROOT/.gui-core"
  if [ ! -d "$CORE/.git" ]; then
    git clone --depth 1 "$REPO" "$CORE"
  fi
fi

exec "$CORE/scripts/build.sh" "$OUT"
