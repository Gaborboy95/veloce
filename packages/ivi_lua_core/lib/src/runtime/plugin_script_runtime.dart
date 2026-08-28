import '../api/plugin_api_registry.dart';
import '../callbacks/plugin_callback_registry.dart';
import '../manifest/plugin_manifest.dart';
import '../values/structured_value.dart';

/// Creates independent script runtimes without exposing native state pointers.
abstract interface class PluginScriptRuntimeFactory {
  Future<PluginScriptRuntime> create({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
  });
}

/// One isolated script state owned by one plugin generation.
abstract interface class PluginScriptRuntime {
  PluginManifest get manifest;
  String get generation;
  bool get isDisposed;

  /// Loads/executes the configured entrypoint but does not impose lifecycle
  /// function names on alternative script implementations.
  Future<void> loadEntrypoint();

  Future<bool> hasFunction(String name);

  Future<StructuredValue> invokeFunction(
    String name, {
    List<StructuredValue> arguments = const [],
  });

  Future<StructuredValue> invokeCallback(
    PluginScriptCallback callback, {
    List<StructuredValue> arguments = const [],
  });

  /// Invalidates callbacks and releases the underlying script state.
  Future<void> dispose();
}

/// Lua-focused public name for the replaceable script-runtime contract.
///
/// The underlying contract deliberately contains no Lua C types, so alternate
/// Lua implementations can replace the native FFI runtime.
typedef LuaRuntime = PluginScriptRuntime;

/// Factory alias paired with [LuaRuntime].
typedef LuaRuntimeFactory = PluginScriptRuntimeFactory;
