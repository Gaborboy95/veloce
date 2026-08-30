#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
IVI_BUILD="${IVI_BUILD:-$HOME/dev/ivi-build}"

BUNDLE="$WORKSPACE/bundle/infotainment_demo-release-x86_64"
HOMESCREEN="$IVI_BUILD/out/usr/local/bin/homescreen"

if [ ! -x "$HOMESCREEN" ]; then
    echo "ERROR: homescreen not found:"
    echo "  $HOMESCREEN"
    exit 1
fi

if [ ! -f "$BUNDLE/lib/libapp.so" ]; then
    echo "ERROR: IVI bundle does not exist."
    echo "Run:"
    echo "  $ROOT/tool/build_ivi.sh"
    exit 1
fi

export LD_LIBRARY_PATH="$IVI_BUILD/out/usr/local/lib:$BUNDLE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export VELOCE_LUA_LIBRARY="$BUNDLE/lib/libveloce_lua_native.so"
export VELOCE_PLUGIN_DIR="${VELOCE_PLUGIN_DIR:-$ROOT/plugins}"
export VELOCE_PLUGIN_STORAGE="${VELOCE_PLUGIN_STORAGE:-$ROOT/.veloce_storage}"

export VELOCE_CAN_INPUT="${VELOCE_CAN_INPUT:-socketcan}"
export VELOCE_SOCKETCAN_INTERFACE="${VELOCE_SOCKETCAN_INTERFACE:-vcan0}"
export VELOCE_CAN_BUS="${VELOCE_CAN_BUS:-comfort}"
export VELOCE_CAN_WRITE_ENABLED="${VELOCE_CAN_WRITE_ENABLED:-false}"

exec "$HOMESCREEN" -b "$BUNDLE"
