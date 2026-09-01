#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Veloce / ivi-homescreen development environment bootstrap.
#
# Validated target:
#   Ubuntu / Debian, x86_64 development host
#
# What it installs/configures:
#   - host build dependencies
#   - Veloce
#   - emb_cli (+ optional compatibility patch)
#   - Flutter SDK pinned to FLUTTER_VERSION
#   - matching Flutter engine (prebuilt when available, source-built otherwise)
#   - ivi-homescreen Wayland/EGL build
#   - persistent vcan0 development interface
#   - helper commands: ivi-build, ivi-run, ivi-dev, ivi-test-can
#
# Examples:
#   ./install_ivi_dev.sh
#   ./install_ivi_dev.sh --root "$HOME/dev" --jobs 8
#   ./install_ivi_dev.sh --emb-patch ./emb_cli-flutter-347-fixes.patch
#   EMB_CLI_REPO=https://github.com/you/emb_cli.git ./install_ivi_dev.sh
#
# Rerunning is safe: existing repositories and cached engines are reused.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${IVI_DEV_ROOT:-$HOME/dev}"
WORKSPACE="${FLUTTER_WORKSPACE:-}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.2}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

VELOCE_REPO="${VELOCE_REPO:-https://github.com/Gaborboy95/veloce.git}"
EMB_CLI_REPO="${EMB_CLI_REPO:-https://github.com/toyota-connected/emb_cli.git}"
IVI_HOMESCREEN_REPO="${IVI_HOMESCREEN_REPO:-https://github.com/toyota-connected/ivi-homescreen.git}"

VELOCE_REF="${VELOCE_REF:-main}"
EMB_CLI_REF="${EMB_CLI_REF:-main}"
IVI_HOMESCREEN_REF="${IVI_HOMESCREEN_REF:-main}"

EMB_PATCH="${EMB_PATCH:-}"

DO_ENGINE=1
DO_DEMO_BUILD=1
DO_VCAN=1
MODIFY_SHELLRC=1
UPDATE_REPOS=0

usage() {
  cat <<'EOF'
Usage: install_ivi_dev.sh [options]

Options:
  --root PATH               Development root (default: ~/dev)
  --workspace PATH          Flutter workspace (default: <root>/infotainment)
  --flutter-version VER     Flutter version/tag (default: 3.47.2)
  --jobs N                  Parallel build jobs (default: nproc)
  --emb-patch PATH|URL      emb_cli compatibility patch
  --update                  Fast-forward clean existing repositories
  --skip-engine             Do not provision/build Flutter engine
  --skip-demo-build         Do not build the Veloce infotainment demo
  --no-vcan                 Do not create persistent vcan0
  --no-shellrc              Do not add generated environment to ~/.bashrc
  -h, --help                Show this help

Environment overrides:
  IVI_DEV_ROOT
  FLUTTER_WORKSPACE
  FLUTTER_VERSION
  JOBS
  VELOCE_REPO / VELOCE_REF
  EMB_CLI_REPO / EMB_CLI_REF
  IVI_HOMESCREEN_REPO / IVI_HOMESCREEN_REF
  EMB_PATCH

Recommended repository layout:
  <root>/veloce
  <root>/emb_cli
  <root>/ivi-homescreen
  <root>/ivi-build
  <root>/infotainment
  <root>/bin
EOF
}

while (($#)); do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || die "--root requires a value"
      ROOT="$2"; shift 2 ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE="$2"; shift 2 ;;
    --flutter-version)
      [[ $# -ge 2 ]] || die "--flutter-version requires a value"
      FLUTTER_VERSION="$2"; shift 2 ;;
    --jobs)
      [[ $# -ge 2 ]] || die "--jobs requires a value"
      JOBS="$2"; shift 2 ;;
    --emb-patch)
      [[ $# -ge 2 ]] || die "--emb-patch requires a value"
      EMB_PATCH="$2"; shift 2 ;;
    --update)
      UPDATE_REPOS=1; shift ;;
    --skip-engine)
      DO_ENGINE=0; shift ;;
    --skip-demo-build)
      DO_DEMO_BUILD=0; shift ;;
    --no-vcan)
      DO_VCAN=0; shift ;;
    --no-shellrc)
      MODIFY_SHELLRC=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

ROOT="$(realpath -m "$ROOT")"
WORKSPACE="${WORKSPACE:-$ROOT/infotainment}"
WORKSPACE="$(realpath -m "$WORKSPACE")"

VELOCE_DIR="$ROOT/veloce"
EMB_DIR="$ROOT/emb_cli"
IVI_SRC="$ROOT/ivi-homescreen"
IVI_BUILD="$ROOT/ivi-build"
BIN_DIR="$ROOT/bin"
ENV_FILE="$ROOT/ivi-env.sh"
DEMO_DIR="$VELOCE_DIR/example/infotainment_demo"
BUNDLE="$WORKSPACE/bundle/infotainment_demo-release-x86_64"

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

# ---------------------------------------------------------------------------
# Host validation
# ---------------------------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "This installer currently targets Linux only."

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "This validated development installer currently targets x86_64 hosts." ;;
esac

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:debian*|*:ubuntu*) ;;
    *)
      die "This installer currently supports Ubuntu/Debian hosts. Detected: ${PRETTY_NAME:-unknown}"
      ;;
  esac
fi

command -v sudo >/dev/null || die "sudo is required."
sudo -v

mkdir -p "$ROOT" "$WORKSPACE" "$BIN_DIR"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

log "Installing host development dependencies"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  git \
  git-lfs \
  python3 \
  build-essential \
  clang \
  cmake \
  ninja-build \
  make \
  pkg-config \
  patch \
  rsync \
  unzip \
  zip \
  xz-utils \
  tar \
  libsystemd-dev \
  packagekit \
  libgtk-3-dev \
  liblzma-dev \
  libwayland-dev \
  wayland-protocols \
  libxkbcommon-dev \
  mesa-common-dev \
  libegl1-mesa-dev \
  libgles2-mesa-dev \
  mesa-utils \
  can-utils \
  iproute2 \
  kmod

git lfs install --skip-repo >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

clone_or_keep() {
  local url="$1"
  local dir="$2"
  local ref="$3"
  local name="$4"

  if [[ ! -e "$dir/.git" ]]; then
    log "Cloning $name"
    git clone --branch "$ref" "$url" "$dir"
    git -C "$dir" submodule update --init --recursive
    return
  fi

  log "$name already exists: $dir"

  if (( UPDATE_REPOS == 0 )); then
    return
  fi

  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    warn "$name has local changes; not updating it."
    return
  fi

  log "Updating $name"
  git -C "$dir" fetch origin

  # Only fast-forward when the requested ref is a branch that exists remotely.
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    git -C "$dir" checkout "$ref"
    git -C "$dir" merge --ff-only "origin/$ref"
  else
    git -C "$dir" checkout "$ref"
  fi

  git -C "$dir" submodule update --init --recursive
}

# Clone Veloce first because it may carry the emb compatibility patch.
clone_or_keep "$VELOCE_REPO" "$VELOCE_DIR" "$VELOCE_REF" "Veloce"
clone_or_keep "$EMB_CLI_REPO" "$EMB_DIR" "$EMB_CLI_REF" "emb_cli"
clone_or_keep "$IVI_HOMESCREEN_REPO" "$IVI_SRC" "$IVI_HOMESCREEN_REF" "ivi-homescreen"

# ---------------------------------------------------------------------------
# emb_cli compatibility patch
# ---------------------------------------------------------------------------

resolve_emb_patch() {
  local candidate

  if [[ -n "$EMB_PATCH" ]]; then
    printf '%s\n' "$EMB_PATCH"
    return
  fi

  for candidate in \
    "$VELOCE_DIR/tool/patches/emb_cli-flutter-347-fixes.patch" \
    "$SCRIPT_DIR/emb_cli-flutter-347-fixes.patch"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '\n'
}

apply_emb_patch() {
  local patch_spec
  local patch_file
  patch_spec="$(resolve_emb_patch)"

  if [[ -z "$patch_spec" ]]; then
    warn "No emb_cli compatibility patch found."
    warn "If your emb_cli fork already contains the Flutter 3.47/source-engine fixes, this is fine."
    warn "Otherwise rerun with --emb-patch PATH, or store the patch at:"
    warn "  $VELOCE_DIR/tool/patches/emb_cli-flutter-347-fixes.patch"
    return
  fi

  if [[ "$patch_spec" =~ ^https?:// ]]; then
    patch_file="$(mktemp)"
    log "Downloading emb_cli compatibility patch"
    curl -fL "$patch_spec" -o "$patch_file"
  else
    patch_file="$(realpath "$patch_spec")"
  fi

  [[ -f "$patch_file" ]] || die "emb patch does not exist: $patch_file"

  if git -C "$EMB_DIR" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    ok "emb_cli compatibility patch is already applied"
  elif git -C "$EMB_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
    log "Applying emb_cli compatibility patch"
    git -C "$EMB_DIR" apply "$patch_file"
  else
    # A custom fork may already contain equivalent fixes with a different diff.
    warn "The emb_cli patch cannot be cleanly applied or reverse-applied."
    warn "Continuing under the assumption that this emb_cli tree already contains equivalent fixes."
  fi

  if [[ "$patch_spec" =~ ^https?:// ]]; then
    rm -f "$patch_file"
  fi
}

apply_emb_patch

# ---------------------------------------------------------------------------
# Bootstrap emb
# ---------------------------------------------------------------------------

log "Bootstrapping emb_cli"
cd "$EMB_DIR"

# bootstrap.sh installs a pinned Dart SDK when necessary and prints PATH exports.
# shellcheck disable=SC2046
eval "$(./bootstrap.sh --shellenv)"

command -v emb >/dev/null || die "emb was not installed onto PATH."
emb --version

# The installed emb executable resolves the package correctly, but the source
# engine recipe is repository-local. Keep this explicit until emb resolves the
# recipe relative to its own installation.
export EMB_ENGINE_BUILD_SCRIPT="$EMB_DIR/tool/engine/build-engine.sh"

# ---------------------------------------------------------------------------
# Flutter SDK
# ---------------------------------------------------------------------------

log "Installing/provisioning Flutter $FLUTTER_VERSION"
emb flutter \
  --workspace "$WORKSPACE" \
  --flutter-version "$FLUTTER_VERSION"

[[ -f "$WORKSPACE/setup_env.sh" ]] || die "emb did not generate $WORKSPACE/setup_env.sh"

# shellcheck disable=SC1090
source "$WORKSPACE/setup_env.sh"

flutter config --enable-linux-desktop >/dev/null
flutter precache --linux
flutter --version

# doctor is informative here; Android toolchain failures are irrelevant to this setup.
flutter doctor -v || true

# ---------------------------------------------------------------------------
# Flutter engine
# ---------------------------------------------------------------------------

if (( DO_ENGINE )); then
  log "Provisioning matching Flutter release engine"
  log "A prebuilt will be reused when available; otherwise this may perform a large source build."

  emb engine \
    --workspace "$WORKSPACE" \
    --arch x86_64 \
    --mode release \
    --build-engine

  ENGINE_COMMIT="$(tr -d '\r\n' < "$WORKSPACE/flutter/bin/internal/engine.version")"
  ENGINE_SO="$WORKSPACE/.config/flutter_workspace/flutter-engine/bundle-release-x86_64/lib/libflutter_engine.so"

  [[ -f "$ENGINE_SO" ]] || die "Engine provisioning finished without staging libflutter_engine.so."
  ok "Flutter engine staged for commit $ENGINE_COMMIT"
else
  warn "Skipping Flutter engine provisioning."
fi

# ---------------------------------------------------------------------------
# ivi-homescreen
# ---------------------------------------------------------------------------

log "Configuring ivi-homescreen (Wayland/EGL)"
cmake \
  -S "$IVI_SRC" \
  -B "$IVI_BUILD" \
  -D CMAKE_BUILD_TYPE=Debug \
  -D CMAKE_STAGING_PREFIX="$IVI_BUILD/out/usr/local" \
  -D BUILD_BACKEND_WAYLAND_EGL=ON \
  -D BUILD_BACKEND_WAYLAND_VULKAN=OFF \
  -D ENABLE_XDG_CLIENT=ON \
  -D ENABLE_DLT=OFF

log "Building ivi-homescreen"
cmake --build "$IVI_BUILD" --target install --parallel "$JOBS"

HOMESCREEN="$IVI_BUILD/out/usr/local/bin/homescreen"
[[ -x "$HOMESCREEN" ]] || die "homescreen binary was not produced at $HOMESCREEN"
ok "ivi-homescreen built: $HOMESCREEN"

# ---------------------------------------------------------------------------
# Veloce Flutter dependencies + optional smoke bundle
# ---------------------------------------------------------------------------

[[ -d "$DEMO_DIR" ]] || die "Veloce infotainment demo not found at $DEMO_DIR"

log "Resolving Veloce demo dependencies"
cd "$DEMO_DIR"
flutter pub get

if (( DO_DEMO_BUILD )); then
  log "Building Veloce IVI smoke-test bundle with emb"
  emb bundle \
    --workspace "$WORKSPACE" \
    --app-path "$DEMO_DIR" \
    --arch x86_64 \
    --mode release \
    --build

  for f in \
    "$BUNDLE/lib/libapp.so" \
    "$BUNDLE/lib/libflutter_engine.so" \
    "$BUNDLE/lib/libveloce_lua_native.so"
  do
    [[ -f "$f" ]] || die "Smoke bundle is missing: $f"
  done

  if ldd "$BUNDLE/lib/libveloce_lua_native.so" | grep -q "not found"; then
    ldd "$BUNDLE/lib/libveloce_lua_native.so" | grep "not found" >&2 || true
    die "Veloce native library has unresolved dependencies."
  fi

  ok "Smoke-test bundle built successfully"
else
  warn "Skipping Veloce demo bundle build."
fi

# ---------------------------------------------------------------------------
# vcan0
# ---------------------------------------------------------------------------

if (( DO_VCAN )); then
  log "Installing persistent vcan0 development interface"

  sudo tee /usr/local/sbin/veloce-vcan0-up >/dev/null <<'EOF'
#!/bin/sh
set -eu
modprobe vcan
if ! ip link show vcan0 >/dev/null 2>&1; then
  ip link add dev vcan0 type vcan
fi
ip link set dev vcan0 up
EOF
  sudo chmod 0755 /usr/local/sbin/veloce-vcan0-up

  sudo tee /etc/systemd/system/veloce-vcan0.service >/dev/null <<'EOF'
[Unit]
Description=Veloce virtual CAN development interface
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/veloce-vcan0-up
ExecStop=/bin/sh -c 'ip link show vcan0 >/dev/null 2>&1 && ip link del dev vcan0 || true'

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now veloce-vcan0.service
  ip link show vcan0 >/dev/null || die "vcan0 service started but vcan0 is unavailable."
  ok "vcan0 is up"
fi

# ---------------------------------------------------------------------------
# Environment + helper commands
# ---------------------------------------------------------------------------

log "Generating development environment"

cat > "$ENV_FILE" <<EOF
# Generated by install_ivi_dev.sh
export IVI_DEV_ROOT="$ROOT"
export FLUTTER_WORKSPACE="$WORKSPACE"
export VELOCE_ROOT="$VELOCE_DIR"
export EMB_CLI_ROOT="$EMB_DIR"
export IVI_HOMESCREEN_ROOT="$IVI_SRC"
export IVI_BUILD="$IVI_BUILD"
export EMB_ENGINE_BUILD_SCRIPT="$EMB_DIR/tool/engine/build-engine.sh"

source "$WORKSPACE/setup_env.sh"

export VELOCE_PLUGIN_DIR="$VELOCE_DIR/plugins"
export VELOCE_PLUGIN_STORAGE="$VELOCE_DIR/.veloce_storage"
export VELOCE_CAN_INPUT="socketcan"
export VELOCE_SOCKETCAN_INTERFACE="vcan0"
export VELOCE_CAN_BUS="comfort"
export VELOCE_CAN_WRITE_ENABLED="false"

export PATH="$BIN_DIR:\$PATH"
EOF

cat > "$BIN_DIR/ivi-build" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ENV_FILE"
exec emb bundle \\
  --workspace "$WORKSPACE" \\
  --app-path "$DEMO_DIR" \\
  --arch x86_64 \\
  --mode release \\
  --build
EOF

cat > "$BIN_DIR/ivi-run" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ENV_FILE"

BUNDLE="$BUNDLE"
HOMESCREEN="$HOMESCREEN"

[[ -f "\$BUNDLE/lib/libapp.so" ]] || {
  echo "Bundle missing. Run: ivi-build" >&2
  exit 1
}

export LD_LIBRARY_PATH="$IVI_BUILD/out/usr/local/lib:\$BUNDLE/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export VELOCE_LUA_LIBRARY="\$BUNDLE/lib/libveloce_lua_native.so"

exec "\$HOMESCREEN" -b "\$BUNDLE"
EOF

cat > "$BIN_DIR/ivi-dev" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$BIN_DIR/ivi-build"
exec "$BIN_DIR/ivi-run"
EOF

cat > "$BIN_DIR/ivi-test-can" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cansend vcan0 280#0BB8
echo "Sent 0x280 / 0BB8 to vcan0 (demo expectation: 3000 RPM)"
EOF

chmod +x \
  "$BIN_DIR/ivi-build" \
  "$BIN_DIR/ivi-run" \
  "$BIN_DIR/ivi-dev" \
  "$BIN_DIR/ivi-test-can"

if (( MODIFY_SHELLRC )); then
  BASHRC="$HOME/.bashrc"
  SOURCE_LINE="source \"$ENV_FILE\""

  touch "$BASHRC"
  if ! grep -Fqx "$SOURCE_LINE" "$BASHRC"; then
    {
      printf '\n# Veloce / IVI development environment\n'
      printf '%s\n' "$SOURCE_LINE"
    } >> "$BASHRC"
    ok "Added IVI environment to $BASHRC"
  fi
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

log "Final verification"

test -x "$HOMESCREEN"
test -x "$BIN_DIR/ivi-build"
test -x "$BIN_DIR/ivi-run"
command -v flutter >/dev/null
command -v emb >/dev/null

if (( DO_VCAN )); then
  ip link show vcan0 >/dev/null
fi

cat <<EOF

============================================================
Veloce IVI development environment is ready
============================================================

Root:
  $ROOT

Flutter workspace:
  $WORKSPACE

Repositories:
  Veloce:          $VELOCE_DIR
  emb_cli:         $EMB_DIR
  ivi-homescreen:  $IVI_SRC

Environment:
  $ENV_FILE

Helper commands:
  ivi-build       Build the embedded Veloce bundle
  ivi-run         Run the current bundle in ivi-homescreen
  ivi-dev         Build, then run
  ivi-test-can    Send the demo 3000 RPM CAN frame

For THIS shell, run:
  source "$ENV_FILE"

Then a complete test is:
  ivi-dev

In another terminal:
  ivi-test-can

EOF
