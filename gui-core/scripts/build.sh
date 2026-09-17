#!/bin/bash
# bash 3.2 (Xcode /bin/bash). Builds fun_gui_core into the given Generated/ dir.
set -e
set -u
set -o pipefail

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

cd "$(dirname "$0")/.."

OUT="${1:?usage: build.sh OUTDIR}"
CRATE_NAME=fun_gui_core
FFI_MODULE_NAME="${CRATE_NAME}FFI"
LIB_NAME="lib${CRATE_NAME}.a"
WORKDIR="target/apple-build"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found (install rustup and reopen Xcode)" >&2
  echo "PATH=$PATH" >&2
  exit 1
fi

profile=release
if [ "${CONFIGURATION-}" = "Debug" ]; then
  profile=debug
fi

platform="${PLATFORM_NAME-}"
targets=""
for arch in ${ARCHS-}; do
  case "$platform:$arch" in
    iphoneos:arm64) targets="$targets aarch64-apple-ios" ;;
    iphonesimulator:arm64) targets="$targets aarch64-apple-ios-sim" ;;
    iphonesimulator:x86_64) targets="$targets x86_64-apple-ios" ;;
    macosx:arm64) targets="$targets aarch64-apple-darwin" ;;
    macosx:x86_64) targets="$targets x86_64-apple-darwin" ;;
    *:arm64) targets="$targets aarch64-apple-darwin" ;;
    *:x86_64) targets="$targets x86_64-apple-darwin" ;;
  esac
done
if [ -z "$targets" ]; then
  case "$platform" in
    iphoneos) targets="aarch64-apple-ios" ;;
    iphonesimulator) targets="aarch64-apple-ios-sim" ;;
    *) targets="aarch64-apple-darwin x86_64-apple-darwin" ;;
  esac
fi

if command -v rustup >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  rustup target add $targets
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bindings" "$OUT"

first_lib=""
libs=""
for target in $targets; do
  echo "==> cargo build (${profile}) ${target}"
  if [ "$profile" = "release" ]; then
    cargo build --release --target "$target"
  else
    cargo build --target "$target"
  fi
  lib="target/${target}/${profile}/${LIB_NAME}"
  if [ -z "$first_lib" ]; then
    first_lib="$lib"
    libs="$lib"
  else
    libs="$libs $lib"
  fi
done

echo "==> Generating Swift bindings"
cargo run --quiet --features uniffi-bindgen --bin uniffi-bindgen -- generate \
  --library "$first_lib" \
  --language swift \
  --out-dir "$WORKDIR/bindings"

cp "$WORKDIR/bindings/${CRATE_NAME}.swift" "$OUT/"
cp "$WORKDIR/bindings/${FFI_MODULE_NAME}.h" "$OUT/"
cp "$WORKDIR/bindings/${FFI_MODULE_NAME}.modulemap" "$OUT/module.modulemap"

set -- $libs
if [ "$#" -eq 1 ]; then
  cp "$1" "$OUT/${LIB_NAME}"
else
  echo "==> Merging architectures"
  lipo -create "$@" -output "$OUT/${LIB_NAME}"
fi

echo "==> Done"
