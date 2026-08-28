# veloce_lua_core

Pure Dart contracts and orchestration for the Veloce Lua plugin runtime. This
package has no Flutter or Lua C dependency. It contains manifest validation,
plugin discovery and watching, transactional lifecycle management, capability
checks, structured values, owner-aware event/vehicle/CAN abstractions,
plugin-scoped storage, logs, timers, callbacks, and the declarative UI model.

Provide a `PluginScriptRuntimeFactory` to supply one independent script runtime
per plugin generation:

```dart
final manager = PluginManager(
  pluginRoot: Directory('/opt/veloce/plugins'),
  runtimeFactory: runtimeFactory,
  canProvider: canProvider,
  storageProvider: storageProvider,
);

await manager.discover();
await manager.startWatching();
```

The built-in API registry is namespaced and capability-bound. Hosts can add
their own `PluginApiNamespace` entries through `manager.apiRegistry` when the
corresponding capability is present in the manager's `CapabilityCatalog`.

See the repository [README](../../README.md),
[authoring guide](../../docs/PLUGIN_AUTHORING.md), and
[threading guide](../../docs/THREADING.md).
