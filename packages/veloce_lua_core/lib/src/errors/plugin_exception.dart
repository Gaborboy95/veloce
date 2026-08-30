import '../runtime/plugin_state.dart';

/// Base class for errors which may be safely surfaced by the plugin manager.
abstract class PluginException implements Exception {
  const PluginException(
    this.message, {
    this.pluginId,
    this.phase,
    this.filename,
    this.line,
    this.cause,
    this.causeStackTrace,
  });

  final String message;
  final String? pluginId;
  final PluginLifecyclePhase? phase;
  final String? filename;
  final int? line;
  final Object? cause;
  final StackTrace? causeStackTrace;

  @override
  String toString() {
    final context = <String>[
      if (pluginId != null) 'plugin=$pluginId',
      if (phase != null) 'phase=${phase!.name}',
      if (filename != null)
        line == null ? 'file=$filename' : 'file=$filename:$line',
    ];
    final suffix = context.isEmpty ? '' : ' (${context.join(', ')})';
    return '$runtimeType: $message$suffix';
  }
}

final class PluginManifestException extends PluginException {
  const PluginManifestException(
    super.message, {
    super.pluginId,
    super.filename = 'manifest.json',
    super.cause,
    super.causeStackTrace,
  }) : super(phase: PluginLifecyclePhase.manifestValidation);
}

class PluginPermissionException extends PluginException {
  const PluginPermissionException(
    super.message, {
    required super.pluginId,
    required this.capability,
    super.phase = PluginLifecyclePhase.running,
    super.cause,
    super.causeStackTrace,
  });

  final String capability;
}

final class PluginLoadException extends PluginException {
  const PluginLoadException(
    super.message, {
    required super.pluginId,
    super.phase = PluginLifecyclePhase.loading,
    super.filename,
    super.line,
    super.cause,
    super.causeStackTrace,
  });
}

final class PluginLuaException extends PluginException {
  const PluginLuaException(
    super.message, {
    required super.pluginId,
    required super.phase,
    super.filename,
    super.line,
    super.cause,
    super.causeStackTrace,
    this.luaStackTrace,
  });

  final String? luaStackTrace;
}

class PluginApiException extends PluginException {
  const PluginApiException(
    super.message, {
    required super.pluginId,
    super.phase = PluginLifecyclePhase.running,
    super.cause,
    super.causeStackTrace,
  });
}

final class PluginReloadException extends PluginException {
  const PluginReloadException(
    super.message, {
    required super.pluginId,
    super.phase = PluginLifecyclePhase.reloading,
    super.filename,
    super.line,
    super.cause,
    super.causeStackTrace,
    this.luaStackTrace,
  });

  /// Native Lua traceback retained when the candidate failed in Lua.
  final String? luaStackTrace;
}

final class PluginStorageException extends PluginException {
  const PluginStorageException(
    super.message, {
    required super.pluginId,
    super.cause,
    super.causeStackTrace,
  }) : super(phase: PluginLifecyclePhase.storage);
}

final class PluginInstallationException extends PluginException {
  const PluginInstallationException(
    super.message, {
    super.pluginId,
    super.filename,
    super.cause,
    super.causeStackTrace,
  }) : super(phase: PluginLifecyclePhase.installation);
}

final class PluginAssetException extends PluginException {
  const PluginAssetException(
    super.message, {
    required super.pluginId,
    super.filename,
    super.cause,
    super.causeStackTrace,
  }) : super(phase: PluginLifecyclePhase.running);
}

final class StalePluginCallbackException extends PluginApiException {
  const StalePluginCallbackException(super.message, {required super.pluginId})
    : super(phase: PluginLifecyclePhase.callback);
}
