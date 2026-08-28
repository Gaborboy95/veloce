# Veloce Lua runtime for Flutter

A modular Lua 5.4 plugin runtime for Flutter-based automotive infotainment
hosts. Plugins are ordinary directories discovered at runtime, and each loaded
plugin receives its own sandboxed Lua state. The host exposes only versioned,
namespaced APIs backed by permission checks and structured data.

This repository is an engineering prototype: it establishes the package
boundaries, safe bridge, lifecycle ownership, transactional reload model,
declarative Flutter UI, in-memory CAN path, and demo plugins. Read
[Known limitations](#known-limitations) before treating it as a production
security boundary.

## What is here

- Dynamic discovery, load, unload, enable/disable, and debounced hot reload.
- A replacement-first reload path: a broken candidate does not replace the
  currently running generation.
- One Lua state and callback generation per loaded plugin.
- Capability checks at the Dart host-API boundary.
- Owner-aware cleanup for subscriptions, timers, callbacks, CAN registrations,
  and UI contributions.
- A structured Dart/Lua value bridge with depth and size limits.
- Abstract event and vehicle-data buses with bounded delivery policies.
- Provider-side CAN filtering and an in-memory CAN provider for demos/tests.
- A validated UI model converted to a small allowlisted set of Flutter widgets.
- Plugin-attributed logs and plugin-scoped in-memory/JSON storage.
- Execution instruction, wall-clock, memory, and timer limits.

## Repository layout

```text
packages/
├── ivi_lua_core/       Pure Dart contracts, models, buses, policy, ownership
│                       registries, loading, watching, and manager foundations
├── ivi_lua_native/     Lua 5.4 C shim, Dart FFI implementation, sandbox
└── ivi_lua_flutter/    UI-model validation and Flutter widget construction

example/
└── infotainment_demo/  Flutter desktop host and developer controls

plugins/
├── hello_ui/           Lua tab, callbacks, timer, reload-state example
├── can_decoder/        Fake CAN 0x280 → engine.rpm adapter
└── vehicle_dashboard/  engine.rpm consumer with no CAN dependency

docs/
├── PLUGIN_AUTHORING.md API v1 and new-plugin workflow
└── THREADING.md        Execution ownership, queues, and hardening path
```

The core package has no Flutter dependency and does not know the application's
business logic. The native implementation is behind a script-runtime
abstraction, so a different Lua implementation can replace it without exposing
Lua C pointers to the manager or host application. Flutter integration consumes
validated UI nodes; it does not expose `Widget`, `BuildContext`, or arbitrary
Dart objects to Lua.

## Architecture

```text
Flutter host / ivi-homescreen integration
│
├── PluginManager
│   ├── PluginLoader + PluginRegistry + PluginWatcher
│   ├── CapabilityManager + namespaced PluginApiRegistry
│   ├── PluginEventBus + VehicleDataBus + CanProvider
│   ├── PluginUiRegistry + generic extension registry
│   ├── PluginStorageProvider + PluginLogManager
│   └── per-generation callbacks and timers
│
├── ivi_lua_flutter
│   └── validated PluginUiNode → Flutter Widget
│
└── PluginScriptRuntime abstraction
    └── NativeLuaRuntime
        └── private FFI shim → independent Lua 5.4 state
```

All resources carry an owner plugin ID; callbacks additionally carry a runtime
generation. This is the central unload/reload invariant: cleanup is performed
by ownership even if plugin teardown code throws, and a widget holding an old
callback ID cannot enter a replacement or destroyed Lua state.

### Vehicle data stays separate from CAN

```text
filtered CAN frame
      ↓
vehicle-specific Lua decoder
      ↓
VehicleDataBus: engine.rpm
      ↓
transport-independent Lua dashboard
      ↓
validated Flutter UI tab
```

Only the decoder requests `can.read`; the dashboard requests `vehicle.read`.
Replacing SocketCAN, a simulator, or the vehicle-specific decoder therefore
does not change consumer plugins.

## Native Lua choice

The runtime builds the official Lua **5.4.9** sources into
`ivi_lua_native`; it does not require `lua` or `liblua` to be installed on the
target. CMake pins both the release URL and SHA-256 digest. The resulting native
library is bundled by the Flutter Linux/Windows plugin build.

Lua is downloaded by CMake's `FetchContent` on the first native build. A
reproducible offline embedded build can unpack the pinned archive and configure
with `-DIVI_LUA_SOURCE_DIR=/path/to/lua-5.4.9`; the source archive is not
currently checked into this repository.

[`flutter_embed_lua` 0.0.2](https://pub.dev/packages/flutter_embed_lua) was
evaluated. Its documented API is centered on `run`, global function
registration, and callbacks that directly receive `Pointer<lua_State>`. It
does not expose the controls this runtime needs as stable, documented
abstractions: a limiting allocator, per-protected-call instruction/deadline
hooks, deliberately selected standard libraries, generation-aware callback
ownership, and a pointer-free replaceable runtime interface. It may suit a
trusted embedded REPL, but adapting it would still require a private native
layer for the safety and lifecycle invariants here. This repository therefore
uses a deliberately small C shim and keeps its FFI types private to
`ivi_lua_native`.

## Plugin format and lifecycle

A minimal plugin is:

```text
plugins/com_example_demo/
├── manifest.json
└── main.lua
```

```json
{
  "id": "com.example.demo",
  "name": "Demo",
  "version": "1.0.0",
  "apiVersion": "1",
  "entrypoint": "main.lua",
  "permissions": ["logging", "ui.tabs"]
}
```

```lua
local ivi = require("ivi")

function on_load(previous_state)
  ivi.log.info("loaded")
end

function on_unload()
  ivi.log.info("unloading")
end
```

The loader validates the ID, semantic version, API version, entrypoint
containment/existence, permissions, and duplicate IDs before execution. A
malformed plugin becomes a structured diagnostic rather than an uncaught host
error.

The supported lifecycle is `on_load([state])` and `on_unload()`, with optional
`on_save_state()` for JSON/Lua-table-compatible reload state. Suspend/resume
hooks are reserved for a future host lifecycle. Detailed rules and API examples
are in [the authoring guide](docs/PLUGIN_AUTHORING.md).

## API v1 and permissions

Lua receives cohesive namespaces rather than a large set of arbitrary globals:

```text
app.*       host-selected read-only information
log.*       attributed logging
events.*    general structured publish/subscribe
vehicle.*   abstract vehicle signals
can.*       filtered transport access
ui.*        declarative UI and extension registration
storage.*   plugin-scoped structured persistence
timer.*     plugin-owned timeouts and intervals
```

Built-in capabilities are:

```text
app.info      logging       events
vehicle.read  vehicle.write
can.read      can.write
ui.tabs       ui.notifications
storage       timer
```

A manifest request is necessary but not sufficient: the host can disable a
capability or apply a per-plugin authorization policy. CAN additionally supports
bus/ID-set/mask grants and maximum write rates. A filter can select one ID,
multiple IDs, or all IDs on a bus. `can.write` is disabled by default.
Unknown capability names fail manifest validation.

Hosts add an API without weakening attribution by registering a namespace of
methods, each tied to a catalogued capability. Every call arrives with the
plugin ID and generation; arguments and results pass through the structured
value codec.

## Declarative Flutter UI

Plugins return immutable intermediate nodes, currently `text`, `icon`, `row`,
`column`, `container`, `button`, `switch`, `slider`, `spacer`, `list`, and
`card`. The Dart validator rejects malformed/oversized trees and Flutter maps
only allowlisted node and icon types to real widgets.

Tabs are the first UI extension point, exposed as a stream from
`PluginUiRegistry`. The underlying registry is generic so settings pages, quick
controls, or other host-defined points can be added without coupling the core
to tabs. Control functions become generation-scoped callback IDs. Lua never
receives a widget constructor, `BuildContext`, reflection handle, or Dart
closure.

## Transactional hot reload

The filesystem watcher coalesces save bursts per plugin directory (350 ms by
default). Reload follows a replacement-first sequence:

```text
change → parse → fresh Lua state → load → initialize → validate
                                                    │
                         failure ───────────────────┴→ discard candidate
                                                    │  keep current plugin
                         success ───────────────────┴→ atomically publish
                                                       clean old generation
```

Diagnostics retain plugin ID, lifecycle phase, source filename, Lua line when
available, and traceback. Watching is a developer convenience, not a secure
installer; production deployments still need package provenance/signature and
an atomic installation policy.

## Sandbox

Each plugin generation has a separate Lua state and limiting allocator. Only
selected base functions plus the table, string, math, and UTF-8 libraries are
opened. `dofile`, `loadfile`, `load`, `print`, `warn`, and `collectgarbage` are
removed; `io`, `os`, `debug`, `package`, coroutine, process/environment access,
and native module loading are not exposed. `require` accepts only the
host-provided `ivi` module. Protected calls install instruction-count and
monotonic deadline hooks.

The bridge carries only null/nil, bool, integer, finite double, string, arrays,
and string-keyed maps/tables. UI callbacks are opaque IDs, never native or Dart
objects.

This is defense in depth inside the Flutter process, not a complete boundary
for hostile native code. Current execution is serialized on the Dart isolate
that owns the Lua state; it is not yet moved to a dedicated isolate or process.
See [the threading guide](docs/THREADING.md) for queue behavior and the planned
isolate/process hardening path.

## Running the desktop demo

The intended development targets are Windows and Ubuntu 24.04/Linux. Use a
current Flutter installation with Dart 3 and a native C/CMake toolchain.

On Ubuntu, install Flutter's normal Linux desktop prerequisites, including a C
compiler, CMake, Ninja, pkg-config, and GTK development headers. A typical
Ubuntu 24.04 setup is:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
flutter config --enable-linux-desktop
flutter doctor -v
```

Then resolve and run the example:

```bash
cd example/infotainment_demo
flutter pub get
flutter run -d linux
```

On Windows, use Visual Studio's Desktop development with C++ workload. Flutter
desktop plugins also require Windows Developer Mode (or an elevated terminal)
so Flutter can generate its package symlinks. Then run:

```powershell
cd example/infotainment_demo
flutter pub get
flutter run -d windows
```

Run the demo from the repository checkout (or configure its plugin root) so it
can find `plugins/`. Its host UI is designed to expose built-in Home, Plugins,
and Developer Console views alongside Lua-contributed tabs. The fake-CAN control
injects an `0x280` frame without requiring a real CAN interface.

The first native build needs network access for the pinned Lua archive unless
`IVI_LUA_SOURCE_DIR` points at an unpacked Lua 5.4.9 source tree.

## Testing and analysis

There is no root workspace runner, so run checks in each package:

```bash
cd packages/ivi_lua_core
dart pub get
dart analyze
dart test

cd ../ivi_lua_native
flutter pub get
flutter analyze
# First build the test library; see packages/ivi_lua_native/README.md.
flutter test

cd ../ivi_lua_flutter
flutter pub get
flutter analyze
flutter test

cd ../../example/infotainment_demo
flutter pub get
flutter analyze
flutter test
flutter build linux
```

Use `flutter build windows` instead of the final command on a Windows host.
Native compile/runtime tests need `build/native/ivi_lua_native` (or an explicit
`IVI_LUA_LIBRARY`) as described in the native package README. A normal Flutter
desktop build instead compiles and bundles that library through the FFI plugin.
The in-memory CAN provider keeps the test suite independent of SocketCAN
hardware.

## Linux and `ivi-homescreen`

The runtime does not depend on Material navigation, an X11 API, or infotainment
business services. Integrate it with Toyota Connected `ivi-homescreen` as a
normal Flutter package composition: construct the manager in the host's
composition root, adapt host services as permission-checked API namespaces,
consume the tab/extension streams in the host UI, and dispose the manager before
the embedder shuts down.

For a stripped Debian image:

- cross-compile and package `libivi_lua_native.so` with the Flutter application;
- do not install or dynamically locate a system `liblua`;
- keep the plugin and storage roots outside the immutable application image and
  grant only the required Unix permissions;
- make production plugin installation authenticated and atomic;
- configure CAN grants and writes explicitly; never make the demo provider a
  production default;
- test the Lua deadline hook and FFI library loading on the target architecture,
  engine build, Wayland compositor, and embedder shutdown path;
- consider a dedicated runtime process before accepting third-party plugins.

## Example plugins

- `plugins/hello_ui` (`dev.example.hello_ui`) registers a tab with a counter,
  increment callback, elapsed-time interval, and reload state.
- `plugins/can_decoder` (`dev.example.can_decoder`) subscribes only to
  `comfort/0x280` with mask `0x7ff`, decodes two big-endian bytes, and publishes
  `engine.rpm`.
- `plugins/vehicle_dashboard` (`dev.example.vehicle_dashboard`) requests no CAN
  permission. It subscribes to `engine.rpm` and renders a dynamic dashboard tab.

## Known limitations

- Lua currently executes on its owning Dart isolate, normally the Flutter host
  isolate. Calls are bounded and serialized but not yet offloaded.
- Isolates do not contain native crashes; a restricted helper process is the
  appropriate stronger boundary for genuinely hostile plugins.
- No production SocketCAN provider is included. CAN write policy exists, but
  the flat manifest schema does not yet express per-plugin bus/ID/rate grants;
  the host supplies those grants.
- The JSON storage provider is a simple replace-on-write prototype, not SQLite,
  encrypted storage, or a multi-process transactional database.
- Tabs are the only implemented Flutter extension-point facade. Notifications,
  settings pages, quick controls, and background services are future work.
- Plugin assets have no host-mediated Lua API yet.
- There is no signed plugin package/installer or rollback repository.
- The native plugin build currently supports Linux and Windows. Embedded target
  toolchains and `ivi-homescreen` integrations require product-specific build
  and lifecycle testing.
- CMake fetches the pinned Lua source on first build; fully offline builds must
  pass an unpacked source tree through `IVI_LUA_SOURCE_DIR` or seed the
  dependency cache.
