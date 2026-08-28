# ivi_lua_flutter

Flutter rendering for the safe, Flutter-independent UI model from
`ivi_lua_core`. `PluginWidgetBuilder` validates every tree at the Flutter
boundary and maps only the allowlisted `text`, `icon`, `row`, `column`,
`container`, `button`, `switch`, `slider`, `spacer`, `list`, and `card` nodes
to Material widgets.

```dart
final builder = PluginWidgetBuilder(
  callbackInvoker: pluginManager.invokeCallback,
  onError: (error, stackTrace) {
    pluginManager.logManager.logger('host.ui').error(error);
  },
);

final widget = builder.build(tab.content!, pluginId: tab.pluginId);
```

Lua never receives a `Widget`, `BuildContext`, Dart closure, or reflection
handle. Interactive nodes contain generation-scoped callback references;
invocation errors and stale callbacks are contained and reported through
`onError`.

See the repository [README](../../README.md) and
[plugin authoring guide](../../docs/PLUGIN_AUTHORING.md) for the UI DSL and
runtime integration.
