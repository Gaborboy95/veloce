#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/example/infotainment_demo"
WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"

cd "$APP"

emb bundle \
  --workspace "$WORKSPACE" \
  --app-path "$APP" \
  --arch x86_64 \
  --mode release \
  --build

BUNDLE="$WORKSPACE/bundle/infotainment_demo-release-x86_64"

for file in \
  "$BUNDLE/lib/libapp.so" \
  "$BUNDLE/lib/libflutter_engine.so" \
  "$BUNDLE/lib/libveloce_lua_native.so"
do
  if [ ! -f "$file" ]; then
    echo "ERROR: missing $(basename "$file")"
    exit 1
  fi
done

if ldd "$BUNDLE/lib/libveloce_lua_native.so" | grep -q "not found"; then
  echo "ERROR: missing Veloce native dependencies:"
  ldd "$BUNDLE/lib/libveloce_lua_native.so" | grep "not found"
  exit 1
fi

echo
echo "IVI bundle ready:"
echo "  $BUNDLE"
