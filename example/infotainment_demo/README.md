# Infotainment demo

Desktop Flutter host for the Veloce Lua runtime. It provides built-in Home,
Plugins, and Developer Console pages, renders Lua-contributed tabs, watches the
repository's `plugins/` directory, and can inject a filtered fake CAN frame that
the decoder plugin turns into `engine.rpm`. The example can also feed that same
filtered provider from Linux SocketCAN or a LAWICEL-compatible serial adapter.

From this directory:

```bash
flutter pub get
flutter run -d linux
```

On Windows use `flutter run -d windows`; Windows Developer Mode must be enabled
so Flutter can create plugin-package symlinks.

The plugin root is resolved from `--plugins PATH`, `--plugins=PATH`, the
`VELOCE_PLUGIN_DIR` environment variable, or the repository layout. Set
`VELOCE_PLUGIN_STORAGE` to change the JSON storage directory and
`VELOCE_LUA_LIBRARY` to use an explicitly built native library during development.

## CAN input

Physical CAN support intentionally lives in the example, not in the reusable
Veloce runtime packages. Select a source with `VELOCE_CAN_INPUT`:

| Value | Behavior |
| --- | --- |
| `auto` | Default. Uses SocketCAN `can0` on Linux; on Windows uses LAWICEL only when `VELOCE_LAWICEL_PORT` is set; otherwise manual injection remains available. |
| `memory` | No hardware input; use the Home-page injection button. |
| `socketcan` | Direct non-blocking Linux `PF_CAN`/`CAN_RAW` input. |
| `lawicel` | LAWICEL/SLCAN ASCII input over a serial/COM port. |

Linux SocketCAN example:

```bash
sudo ip link set can0 up type can bitrate 500000
export VELOCE_CAN_INPUT=socketcan
export VELOCE_SOCKETCAN_INTERFACE=can0
export VELOCE_CAN_BUS=comfort
flutter run -d linux
```

The reader accepts Classical CAN and CAN FD data frames. RTR and error frames
are deliberately ignored because the core `CanFrame` model does not represent
them. Frames are polled non-blockingly in bounded batches and then enter the
same provider-side subscription filters used by manual injection. See the
[Linux kernel SocketCAN documentation](https://docs.kernel.org/networking/can.html)
for interface setup and raw-socket semantics.

Windows LAWICEL/CANUSB example:

```powershell
$env:VELOCE_CAN_INPUT = "lawicel"
$env:VELOCE_LAWICEL_PORT = "COM3"
$env:VELOCE_CAN_BITRATE = "500000"
$env:VELOCE_CAN_BUS = "comfort"
flutter run -d windows
```

Optional `VELOCE_LAWICEL_SERIAL_BAUD` defaults to `115200`. The adapter is
initialized with `C`, the appropriate standard `S0`–`S8` bitrate command, and
`O`. The parser accepts standard `t` and extended `T` data records, with
optional LAWICEL timestamps. RTR records are ignored. This path uses the
adapter's virtual COM port through `flutter_libserialport`; no vendor DLL API is
required. Command framing follows the
[LAWICEL CANUSB ASCII manual](https://www.canusb.com/docs/canusb_manual.pdf).
The bundled native `libserialport` library is LGPL-3.0-or-later; downstream
distributions must satisfy its license obligations.

The example is read-only: Lua CAN writes remain disabled. Hardware adapters,
bus termination, electrical isolation, permissions, reconnect policy, and
safety validation remain deployment responsibilities.

Use **Inject 3000 RPM frame** to exercise:

```text
comfort CAN 0x280 -> can_decoder -> engine.rpm -> vehicle_dashboard
```

Editing `main.lua` in an example plugin triggers a debounced transactional
reload. Syntax or initialization failures are shown on the Plugins page while
the previous generation remains active.
