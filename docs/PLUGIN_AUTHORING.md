# Lua plugin authoring guide

This guide describes host API version `1`. A plugin is a directory that can be
installed or replaced without recompiling the Flutter host:

```text
my_plugin/
├── manifest.json
├── main.lua
└── assets/                 # optional, host-mediated read-only files
```

## Manifest

```json
{
  "id": "com.example.my_plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "apiVersion": "1",
  "entrypoint": "main.lua",
  "permissions": [
    "logging",
    "events",
    "vehicle.read",
    "ui.tabs",
    "ui.render",
    "assets.read"
  ]
}
```

The loader validates a manifest before executing Lua:

- `id` is a lower-case reverse-domain identifier, for example
  `com.example.my_plugin`;
- `name` is a non-empty display name of at most 128 characters;
- `version` is a semantic version such as `1.2.0` or `1.2.0-beta.1`;
- `apiVersion` is currently exactly `1`;
- `entrypoint` is a relative `.lua` path contained by the plugin directory;
- `permissions` is an array with no duplicates or unknown capability names;
- two discovered directories may not declare the same plugin ID.

Absolute paths, `..`, backslashes, symlink escape, a missing entrypoint, and
malformed UTF-8 are rejected. A rejected plugin is reported to the host; it is
not executed and does not stop discovery of other plugins.

## Lifecycle

The entrypoint may define these global functions:

```lua
function on_load(previous_state)
  -- Register subscriptions, timers, and UI here.
end

function on_save_state()
  return { counter = 42 }
end

function on_unload()
  -- Optional final notification. The host still performs owned cleanup.
end

function on_suspend()
end

function on_resume()
end
```

`on_load` and `on_unload` are supported lifecycle hooks. `on_save_state` is
used when the host requests migration during reload. Suspend/resume are
reserved lifecycle names; a host can opt into them as that lifecycle is added.

State is optional. It must use only bridge-safe values: `nil`, booleans,
finite numbers, strings, arrays, and string-keyed tables. Functions, userdata,
threads, cyclic tables, NaN, and infinities cannot migrate. A migration error
is diagnostic, never a reason to tear down the old working generation.

The host owns everything registered by a plugin. Unload invalidates callbacks,
cancels timers, removes event/vehicle/CAN subscriptions, removes UI extension
contributions, and then destroys that generation's Lua state. `on_unload`
should not be relied upon for safety-critical cleanup.

## Importing API v1

The API is available both through namespaces and through the sandboxed `veloce`
module:

```lua
local veloce = require("veloce")
local log = veloce.log
local ui = veloce.ui
```

Only `require("veloce")` is supported. General Lua module and native-library
loading are intentionally unavailable.

Every operation crosses a Dart dispatcher as the calling plugin ID and runtime
generation. The dispatcher checks the operation's capability; Lua never
receives an underlying Dart object or raw native pointer.

## Permissions

| Capability | API it permits | Notes |
| --- | --- | --- |
| `app.info` | `app.info` | Read-only plugin ID, version, API version, and runtime generation. |
| `logging` | `log.*` | Log records are automatically attributed to the plugin. |
| `events` | `events.subscribe`, `events.publish` | General structured events. |
| `vehicle.read` | `vehicle.subscribe` | Abstract signals, independent of CAN. |
| `vehicle.write` | `vehicle.publish` | Normally granted only to trusted adapters/decoders. |
| `can.read` | `can.subscribe` | Also constrained by the host's bus/ID-set/mask grant. |
| `can.write` | `can.send` | Disabled by default; also needs a host grant and rate limit. |
| `ui.tabs` | tab registration/update/removal | UI is a validated declarative tree. |
| `ui.render` | retain declarative control callbacks and generic extensions | Required by interactive controls and `ui.register_extension`. |
| `ui.settings` | `ui.settings.pages` extension contributions | Host chooses where/how to present them. |
| `ui.quick_controls` | `ui.quick_controls` contributions | Intended for bounded quick-control surfaces. |
| `ui.status` | `ui.status.widgets` contributions | Intended for compact status surfaces. |
| `ui.notifications` | `ui.notifications` contributions | Declarative notification content, not arbitrary Flutter access. |
| `assets.read` | `assets.*` | Read-only access to a bounded snapshot of this plugin's `assets/`. |
| `storage` | `storage.*` | Permanently scoped to the calling plugin ID. |
| `timer` | `timer.*` | Timers and their callbacks are generation-owned. |

Declaring a capability requests it; it does not force the host to grant it.
The host can disable a capability globally or deny it for one plugin. Unknown
permissions make the manifest invalid. `can.write` is deliberately absent from
the safe host defaults.

## Structured values

The bridge accepts these shapes:

```text
Lua nil                   ↔ Dart null
Lua boolean               ↔ Dart bool
Lua integer               ↔ Dart int
Lua number                ↔ Dart finite double
Lua string                ↔ Dart String
Lua sequence table        ↔ immutable Dart list
Lua string-keyed table    ↔ immutable Dart map
```

Mixed-key tables, sparse arrays, functions (except where an API explicitly
expects a callback), userdata, and cyclic tables are rejected. The bridge also
enforces depth, collection-size, and string-size limits. These constraints
apply to events, vehicle values, storage, state migration, callback arguments,
and API results. Lua has no intrinsic empty-array marker, so a bare empty table
crosses the generic bridge as an empty map; APIs that need an empty sequence
must define that case explicitly.

## API reference

### `app`

```lua
local info = app.info()
```

Returns structured information selected by the host. Do not depend on fields
that are not documented by the embedding application.

### `log`

```lua
log.debug("value", 10)
log.info("ready")
log.warn("unexpected input")
log.error("operation failed")
```

Arguments are converted to strings and joined for one attributed log record.
Log history in the provided manager is bounded.

### `events`

```lua
events.subscribe("vehicle.ignition", function(event)
  log.info("ignition value", event)
end)

events.publish("com_example_my_plugin.changed", {
  value = 123,
})
```

The callback receives the published payload, not a host event object. Topics
are exact-match dotted names; API v1 has no wildcard subscription.
Subscriptions are removed on unload. Each subscriber has a bounded sequential
queue, so overload can drop deliveries rather than consume unbounded memory.
Do not use the event bus for raw CAN fan-out.

### `vehicle`

```lua
vehicle.subscribe("engine.rpm", function(rpm)
  log.info("RPM:", rpm)
end)

vehicle.publish("engine.rpm", 2500)
```

Vehicle paths are dotted abstract signal names. A slow subscriber keeps at
most the newest pending value, which intentionally coalesces intermediate
updates. Consumers should treat updates as current state, not an audit log.

Keep transport decoding separate from consumers:

```text
CAN provider → vehicle-specific decoder → VehicleDataBus → generic plugins
```

### `can`

```lua
can.subscribe({
  bus = "comfort",
  id = 0x280,
  mask = 0x7FF,
  extended = false,
}, function(frame)
  local rpm = frame.data[1] * 256 + frame.data[2]
  vehicle.publish("engine.rpm", rpm)
end)
```

Omit both `id` and `ids` to receive every identifier on a bus, or use `ids` to
match any identifier in an array:

```lua
-- Every standard frame on the comfort bus.
can.subscribe({
  bus = "comfort",
  extended = false,
}, handle_comfort_frame)

-- Either ID, using the same mask for each candidate.
can.subscribe({
  bus = "comfort",
  ids = { 0x280, 0x281 },
  mask = 0x7FF,
}, handle_selected_frame)
```

`id` and `ids` are mutually exclusive. `mask` is optional and defaults to the
full standard or extended identifier width. It has no effect when both ID
fields are omitted. `include_remote` and `include_errors` default to `false`.
The provider evaluates these fields before a matching frame enters the plugin
callback queue. A data frame has this shape:

```lua
{
  bus = "comfort",
  type = "data",
  id = 0x280,
  data = { 0x0B, 0xB8 },
  extended = false,
  timestamp_micros = 123456789 -- optional
}
```

RTR callbacks have `type = "remote"`, an empty `data` array, and `length`.
Controller error callbacks require `include_errors = true`; they have
`type = "error"`, `error_flags` using SocketCAN's `CAN_ERR_*` bit layout, and
up to eight controller-detail bytes. Error frames cannot be transmitted.

CAN access is declared in the manifest as well as in `permissions`:

```json
{
  "permissions": ["can.read", "can.write"],
  "can": {
    "read": [
      { "bus": "comfort", "ids": [640, 641], "mask": 2047 }
    ],
    "write": [
      { "bus": "comfort", "id": 1280, "mask": 2047 }
    ],
    "maxSendRatePerSecond": 5
  }
}
```

Manifest filter booleans use JSON names `includeRemote` and `includeErrors`.
The runtime creates a separate authorization owner for every generation, so a
transactional candidate cannot alter the working generation's grants.

Sending is prepared but privileged:

```lua
can.send({
  bus = "comfort",
  id = 0x500,
  data = { 0x01, 0x02, 0x03 },
  extended = false,
})

can.send({
  type = "remote",
  bus = "comfort",
  id = 0x501,
  length = 4,
})
```

It requires all of the following: the manifest requests `can.write`, the host
enables `can.write`, the provider enables writes, the frame matches the
plugin's configured bus/ID grant, and the plugin remains within its maximum
send rate. Use the in-memory provider for development. Transport code remains
outside the reusable packages; the desktop example supports opt-in SocketCAN
and LAWICEL transmission as well as input.

### `storage`

```lua
storage.set("theme", { accent = "blue" })
local theme = storage.get("theme")
local exists = storage.contains("theme")
storage.remove("theme")
```

Keys are scoped by the calling plugin ID. The core offers in-memory, atomic
JSON-file, and SQLite providers. The example uses SQLite. Storage is not
encrypted; use a platform-appropriate encrypted database/key strategy when the
stored values are sensitive.

### `assets`

With `assets.read`, Lua can read only the immutable generation snapshot loaded
from its own `assets/` directory:

```lua
local text = assets.read_text("config/defaults.json")
local bytes = assets.read_bytes("icons/seat.bin")
local exists = assets.exists("icons/seat.bin")
local names = assets.list("icons/")
```

Paths are relative, forward-slash-separated, and cannot contain `.`/`..`,
backslashes, control characters, absolute roots, or symlink entries. File count,
individual size, and total snapshot size are bounded before Lua initialization.
Lua never receives a filesystem path or file handle.

### `timer`

```lua
local timeout = timer.set_timeout(1000, function()
  log.info("once")
end)

local interval = timer.set_interval(500, function()
  log.info("tick")
end)

timer.clear(interval)
```

The host limits timer count, delay, and minimum repeat interval. An interval
does not overlap its own still-running callback. Handles and callbacks are
valid only for the generation that created them, and unload cancels them.

### `ui`

Lua creates a data model; Flutter alone creates widgets. The v1 node set is:

- `text`
- `icon`
- `row`
- `column`
- `container`
- `button`
- `switch`
- `slider`
- `spacer`
- `list`
- `card`

Register a tab with a renderer:

```lua
local counter = 0
local tab_id = "demo"

local function render()
  return ui.column({
    ui.text("Counter: " .. tostring(counter)),
    ui.button({
      text = "Increment",
      on_click = function()
        counter = counter + 1
        ui.refresh_tab(tab_id)
      end,
    }),
  })
end

function on_load()
  ui.register_tab({
    id = tab_id,
    title = "Demo",
    render = render,
  })
end
```

`ui.refresh_tab(id)` re-renders and validates the tree before replacing the
tab content. `ui.unregister_tab(id)` removes a tab explicitly; unload removes
all tabs owned by the plugin regardless. Button, switch, and slider functions
are stored as opaque callback IDs. Flutter invokes that ID through the current
generation's callback registry. A stale widget cannot call a destroyed state.

UI validation limits depth, total nodes, children per node, text length,
dimensions, colors, and control ranges. Icon names are resolved only through
the Flutter package's allowlist. Lua cannot instantiate a widget, access a
`BuildContext`, import a Dart library, or hold a Dart object.

Tabs are a facade over a generic extension registry. Future host versions can
also consume settings pages, quick controls, status widgets, and notifications:

```lua
ui.register_extension({
  point = "ui.quick_controls",
  id = "heated_seat",
  title = "Heated seat",
  render = function()
    return ui.switch({
      label = "Driver seat",
      value = enabled,
      on_change = set_enabled,
    })
  end,
})
```

Use `ui.unregister_extension(point, id)` for explicit removal. The point's
capability and `ui.render` are both checked; unload removes every contribution
regardless. Hosts consume `PluginUiRegistry.contributions(point)` and decide
where the validated model appears.

## Hot reload behavior

The watcher debounces file-save bursts per plugin directory. A reload is a
two-generation transaction:

1. Parse the changed manifest and entrypoint.
2. Create a fresh Lua state and callback/resource generation.
3. Load the entrypoint and call `on_load`, optionally with saved structured
   state.
4. Validate staged registrations.
5. Atomically publish the replacement generation.
6. Run old-generation unload and ownership cleanup, then destroy its Lua state.

If parsing, compilation, initialization, state transfer, or validation fails,
the candidate is disposed and the current generation stays active. The host
reports the plugin ID, phase, file, Lua line when available, and Lua traceback.

File watching is a development feature. `PluginInstaller` provides the
production-oriented directory flow: validate, enforce size/link rules, compute
a canonical SHA-256 package digest, verify a trusted Ed25519 signature, copy to
a same-filesystem hidden staging directory, then atomically rename. Replaced
versions remain as verified rollback candidates and provenance is recorded.

`signature.json` is excluded from the signed payload and has this form:

```json
{
  "algorithm": "ed25519",
  "keyId": "manufacturer-2026",
  "digest": "64 lowercase SHA-256 hex characters",
  "signature": "base64 Ed25519 signature over the 32 digest bytes"
}
```

Use `PluginInstaller.computeDigest` in a trusted packaging tool. Configure
`Ed25519PluginSignatureVerifier` with trusted public keys and optional plugin-ID
allowlists. `requireSignature` defaults to `true`; disable it only for an
explicit developer installation path.

## Sandbox contract

The native state opens only selected parts of the base library plus table,
string, math, and UTF-8. It removes `dofile`, `loadfile`, `load`, `print`,
`warn`, and `collectgarbage`; it does not open `io`, `os`, `debug`, `package`,
or coroutine/native loading. `require` is replaced with an `veloce`-only loader.

Each plugin generation gets a distinct Lua state, Dart isolate, and limiting
allocator. Native protected calls apply instruction-count and monotonic-time
budgets. A runaway plugin cannot occupy the Flutter UI isolate, but Dart
isolates are not process isolation. A defect in native code, a compromised
native library, or an as-yet-unknown Lua vulnerability can still affect the
host process. See
[THREADING.md](THREADING.md) for the current execution model and hardening path.

## Create a new plugin

1. Copy `plugins/hello_ui` to a new directory under the configured plugin root.
2. Give it a unique reverse-domain `id`, semantic `version`, and only the
   permissions it actually uses.
3. Keep `apiVersion` at `1` and implement `main.lua` using `require("veloce")`.
4. Put registrations in `on_load`; optionally return structured state from
   `on_save_state`.
5. Start the demo, inspect the Plugins and Developer Console pages, and edit
   the Lua file to exercise transactional reload.
6. Test a syntax error and an `on_load` error deliberately. The old generation
   should remain present and the diagnostic should identify the failing phase.
7. Test disable/unload and confirm its tabs, callbacks, subscriptions, and
   timers disappear.

Use `plugins/can_decoder` as the transport-adapter example and
`plugins/vehicle_dashboard` as the transport-independent consumer example.
