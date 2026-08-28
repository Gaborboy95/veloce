# Infotainment demo

Desktop Flutter host for the IVI Lua runtime. It provides built-in Home,
Plugins, and Developer Console pages, renders Lua-contributed tabs, watches the
repository's `plugins/` directory, and can inject a filtered fake CAN frame that
the decoder plugin turns into `engine.rpm`.

From this directory:

```bash
flutter pub get
flutter run -d linux
```

On Windows use `flutter run -d windows`; Windows Developer Mode must be enabled
so Flutter can create plugin-package symlinks.

The plugin root is resolved from `--plugins PATH`, `--plugins=PATH`, the
`IVI_PLUGIN_DIR` environment variable, or the repository layout. Set
`IVI_PLUGIN_STORAGE` to change the JSON storage directory and
`IVI_LUA_LIBRARY` to use an explicitly built native library during development.

Use **Inject 3000 RPM frame** to exercise:

```text
comfort CAN 0x280 -> can_decoder -> engine.rpm -> vehicle_dashboard
```

Editing `main.lua` in an example plugin triggers a debounced transactional
reload. Syntax or initialization failures are shown on the Plugins page while
the previous generation remains active.
