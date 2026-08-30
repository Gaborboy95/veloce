#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/example/infotainment_demo"

WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
MODE="release"
ARCH="x86_64"
FLUTTER_ARCH="x64"

OUT="$WORKSPACE/bundle/infotainment_demo-${MODE}-${ARCH}"

# ---------------------------------------------------------------------------
# Flutter environment
# ---------------------------------------------------------------------------

if [ -f "$WORKSPACE/setup_env.sh" ]; then
    # shellcheck disable=SC1090
    source "$WORKSPACE/setup_env.sh"
fi

FLUTTER="$WORKSPACE/flutter/bin/flutter"

if [ ! -x "$FLUTTER" ]; then
    echo "ERROR: Flutter not found at:"
    echo "  $FLUTTER"
    exit 1
fi

COMMIT="$(tr -d '\r\n' < "$WORKSPACE/flutter/bin/internal/engine.version")"

echo "Flutter engine commit:"
echo "  $COMMIT"

# ---------------------------------------------------------------------------
# Locate the source-built embedded engine
# ---------------------------------------------------------------------------

ENGINE_SDK="$HOME/.cache/emb/store/engine/${COMMIT}-linux-${ARCH}-${MODE}-glibc/root/engine-sdk"

if [ ! -f "$ENGINE_SDK/lib/libflutter_engine.so" ]; then
    echo
    echo "ERROR: source-built Flutter engine not found:"
    echo "  $ENGINE_SDK"
    echo
    echo "Build/provision the engine first."
    exit 1
fi

if [ ! -f "$ENGINE_SDK/data/icudtl.dat" ]; then
    echo "ERROR: icudtl.dat missing from engine SDK"
    exit 1
fi

echo
echo "Embedded engine:"
echo "  $ENGINE_SDK"

# ---------------------------------------------------------------------------
# Keep emb's workspace staging synchronized too
# ---------------------------------------------------------------------------

PLATFORM="$WORKSPACE/.config/flutter_workspace/flutter-engine"
ENGINE_STAGE="$PLATFORM/bundle-${MODE}-${ARCH}"

mkdir -p "$ENGINE_STAGE/data"
mkdir -p "$ENGINE_STAGE/lib"

cp "$ENGINE_SDK/data/icudtl.dat" \
   "$ENGINE_STAGE/data/icudtl.dat"

cp "$ENGINE_SDK/lib/libflutter_engine.so" \
   "$ENGINE_STAGE/lib/libflutter_engine.so"

# This is the key format EngineArtifacts expects for the staged bundle.
printf '%s\n' "${COMMIT}-${ARCH}-${MODE}" \
    > "$ENGINE_STAGE/.emb-engine-key"

# Also expose the full engine SDK where emb expects a per-commit SDK.
SDK_LINK="$PLATFORM/$COMMIT/engine-sdk-${MODE}-${ARCH}"

mkdir -p "$(dirname "$SDK_LINK")"
rm -rf "$SDK_LINK"
ln -s "$ENGINE_SDK" "$SDK_LINK"

# ---------------------------------------------------------------------------
# Build with Flutter's normal Linux release pipeline
#
# IMPORTANT:
# This is intentional.
#
# It gives us:
#   - product-compatible libapp.so
#   - Veloce's ffiPlugin .so
#   - Flutter assets
#
# All three are already proven to work with our embedded engine.
# ---------------------------------------------------------------------------

echo
echo "Building Flutter Linux release..."

cd "$APP"

"$FLUTTER" pub get
"$FLUTTER" build linux --release

DESKTOP_BUNDLE="$APP/build/linux/$FLUTTER_ARCH/release/bundle"

if [ ! -d "$DESKTOP_BUNDLE" ]; then
    DESKTOP_BUNDLE="$(
        find "$APP/build/linux" \
            -type d \
            -path '*/release/bundle' \
            -print \
            -quit
    )"
fi

if [ -z "${DESKTOP_BUNDLE:-}" ] || [ ! -d "$DESKTOP_BUNDLE" ]; then
    echo "ERROR: Flutter Linux release bundle not found."
    exit 1
fi

echo
echo "Flutter release bundle:"
echo "  $DESKTOP_BUNDLE"

# ---------------------------------------------------------------------------
# Assemble the ivi-homescreen bundle ourselves
# ---------------------------------------------------------------------------

rm -rf "$OUT"

mkdir -p "$OUT/data"
mkdir -p "$OUT/lib"

cp -a \
    "$DESKTOP_BUNDLE/data/flutter_assets" \
    "$OUT/data/flutter_assets"

# Use ICU from the SAME embedded engine.
cp \
    "$ENGINE_SDK/data/icudtl.dat" \
    "$OUT/data/icudtl.dat"

# Product-compatible Flutter-generated AOT image.
cp \
    "$DESKTOP_BUNDLE/lib/libapp.so" \
    "$OUT/lib/libapp.so"

# Our source-built embedded engine.
cp \
    "$ENGINE_SDK/lib/libflutter_engine.so" \
    "$OUT/lib/libflutter_engine.so"

# ---------------------------------------------------------------------------
# Copy native Flutter plugin / FFI libraries.
#
# libflutter_linux_gtk.so belongs to the normal GTK embedder and must NOT
# replace anything in the ivi-homescreen environment.
# ---------------------------------------------------------------------------

shopt -s nullglob

for lib in "$DESKTOP_BUNDLE"/lib/*.so*; do
    name="$(basename "$lib")"

    case "$name" in
        libapp.so|libflutter_linux_gtk.so)
            continue
            ;;
    esac

    cp -a "$lib" "$OUT/lib/"
done

shopt -u nullglob

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [ ! -f "$OUT/lib/libveloce_lua_native.so" ]; then
    echo
    echo "ERROR: libveloce_lua_native.so was not produced."
    exit 1
fi

if strings "$OUT/lib/libflutter_engine.so" \
    | grep -q "Could not find isolate snapshot data"; then
    echo
    echo "ERROR: old Flutter engine was packaged."
    exit 1
fi

if ! nm -D "$OUT/lib/libapp.so" \
    | grep -q "_kDartSnapshotData"; then
    echo
    echo "ERROR: libapp.so does not contain the expected Dart AOT symbols."
    exit 1
fi

MISSING="$(
    ldd "$OUT/lib/libveloce_lua_native.so" \
        | grep "not found" \
        || true
)"

if [ -n "$MISSING" ]; then
    echo
    echo "ERROR: native Veloce dependencies are missing:"
    echo "$MISSING"
    exit 1
fi

echo
echo "============================================================"
echo "IVI bundle built successfully"
echo "============================================================"
echo
echo "$OUT"
echo
echo "Engine:"
sha256sum "$OUT/lib/libflutter_engine.so"

echo
echo "AOT symbols:"
nm -D "$OUT/lib/libapp.so" | grep kDart

echo
echo "Native libraries:"
find "$OUT/lib" -maxdepth 1 -type f -printf '  %f\n' | sort
