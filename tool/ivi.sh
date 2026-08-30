#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/tool/build_ivi.sh"
exec "$ROOT/tool/run_ivi.sh"
