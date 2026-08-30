import 'dart:developer' as developer;
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

import 'can_input.dart';

final class DemoEnvironment {
  const DemoEnvironment._({required this.values, required this.sourceFile});

  final Map<String, String> values;
  final File? sourceFile;

  static Future<DemoEnvironment> load(
    List<String> arguments, {
    Map<String, String>? processEnvironment,
  }) async {
    final processValues = processEnvironment ?? Platform.environment;
    final explicitPath = _explicitPath(arguments);
    final source = explicitPath == null
        ? _findDefaultFile()
        : File(explicitPath).absolute;
    if (explicitPath != null && !await source.exists()) {
      throw FileSystemException(
        'Explicit environment file does not exist',
        source.path,
      );
    }

    final fileValues = await source.exists()
        ? await _parseFile(source)
        : const <String, String>{};
    return DemoEnvironment._(
      values: Map.unmodifiable({...fileValues, ...processValues}),
      sourceFile: await source.exists() ? source : null,
    );
  }

  static String? _explicitPath(List<String> arguments) {
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument.startsWith('--env-file=')) {
        final value = argument.substring('--env-file='.length);
        if (value.isEmpty) {
          throw const FormatException('--env-file path must not be empty.');
        }
        return value;
      }
      if (argument == '--env-file') {
        if (index + 1 >= arguments.length || arguments[index + 1].isEmpty) {
          throw const FormatException('--env-file requires a path.');
        }
        return arguments[index + 1];
      }
    }
    return null;
  }

  static File _findDefaultFile() {
    final current = Directory.current.absolute;
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final candidates = [
      File('${current.path}${Platform.pathSeparator}.env'),
      File(
        '${current.path}${Platform.pathSeparator}example'
        '${Platform.pathSeparator}infotainment_demo'
        '${Platform.pathSeparator}.env',
      ),
      File('${executableDirectory.path}${Platform.pathSeparator}.env'),
    ];
    return candidates.firstWhere(
      (file) => file.existsSync(),
      orElse: () => candidates.first,
    );
  }

  static Future<Map<String, String>> _parseFile(File file) async {
    final result = <String, String>{};
    final lines = await file.readAsLines();
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index];
      if (index == 0 && line.startsWith('\ufeff')) line = line.substring(1);
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) line = line.substring(7).trimLeft();

      final separator = line.indexOf('=');
      if (separator <= 0) {
        throw FormatException(
          'Invalid environment assignment in ${file.path}:${index + 1}.',
        );
      }
      final key = line.substring(0, separator).trim();
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
        throw FormatException(
          'Invalid environment key in ${file.path}:${index + 1}.',
        );
      }
      result[key] = _parseValue(
        line.substring(separator + 1).trim(),
        file: file,
        lineNumber: index + 1,
      );
    }
    return result;
  }

  static String _parseValue(
    String raw, {
    required File file,
    required int lineNumber,
  }) {
    if (raw.isEmpty) return '';
    final quote = raw.codeUnitAt(0);
    if (quote == 0x27 || quote == 0x22) {
      if (raw.length < 2 || raw.codeUnitAt(raw.length - 1) != quote) {
        throw FormatException(
          'Unterminated quoted value in ${file.path}:$lineNumber.',
        );
      }
      final value = raw.substring(1, raw.length - 1);
      return quote == 0x22 ? _unescapeDoubleQuoted(value) : value;
    }

    final comment = RegExp(r'\s+#').firstMatch(raw);
    return (comment == null ? raw : raw.substring(0, comment.start))
        .trimRight();
  }

  static String _unescapeDoubleQuoted(String value) {
    final output = StringBuffer();
    for (var index = 0; index < value.length; index++) {
      final character = value[index];
      if (character != '\\' || index + 1 >= value.length) {
        output.write(character);
        continue;
      }
      final escaped = value[++index];
      output.write(switch (escaped) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '\\' => '\\',
        '"' => '"',
        _ => escaped,
      });
    }
    return output.toString();
  }
}

final class DemoRuntime {
  DemoRuntime({
    required this.manager,
    required this.canProvider,
    required this.canInput,
    required this.pluginDirectory,
    CanProvider? hostCanProvider,
    this.closableStorageProvider,
  }) : _hostCanProvider = hostCanProvider ?? canProvider;

  final PluginManager manager;
  final InMemoryCanProvider canProvider;
  final DemoCanInputController canInput;
  final Directory pluginDirectory;
  final CanProvider _hostCanProvider;
  final ClosablePluginStorageProvider? closableStorageProvider;

  static Future<DemoRuntime> create(List<String> arguments) async {
    final environment = await DemoEnvironment.load(arguments);
    developer.log(
      environment.sourceFile == null
          ? 'No .env file found; using process environment and defaults.'
          : 'Loaded environment file: ${environment.sourceFile!.path}',
      name: 'veloce.environment',
    );
    final values = environment.values;
    final pluginDirectory = _resolvePluginDirectory(arguments, values);
    final storageRoot = Directory(
      values['VELOCE_PLUGIN_STORAGE'] ??
          '${Directory.current.path}${Platform.pathSeparator}.veloce_plugin_storage',
    );
    final canWritesEnabled = _environmentBool(
      values,
      'VELOCE_CAN_WRITE_ENABLED',
      false,
    );
    final canProvider = InMemoryCanProvider(writesEnabled: canWritesEnabled);
    final canInput = DemoCanInputController.fromEnvironment(values);
    final hostCanProvider = DemoCanTransportProvider(
      memory: canProvider,
      controller: canInput,
    );
    final capabilities = CapabilityManager();
    if (canWritesEnabled) {
      capabilities.setHostCapabilityEnabled(
        BuiltInCapabilities.canWrite,
        enabled: true,
      );
    }
    final sqliteStorage = SqlitePluginStorageProvider(
      databaseFile: File.fromUri(storageRoot.uri.resolve('plugins.sqlite3')),
    );
    final nativePath = values['VELOCE_LUA_LIBRARY'];
    final manager = PluginManager(
      pluginRoot: pluginDirectory,
      runtimeFactory: IsolatedNativeLuaRuntimeFactory(libraryPath: nativePath),
      capabilityManager: capabilities,
      canProvider: hostCanProvider,
      storageProvider: sqliteStorage,
    );
    await manager.discover();
    await manager.startWatching();
    await canInput.start(canProvider);
    return DemoRuntime(
      manager: manager,
      canProvider: canProvider,
      canInput: canInput,
      pluginDirectory: pluginDirectory,
      hostCanProvider: hostCanProvider,
      closableStorageProvider: sqliteStorage,
    );
  }

  Future<void> dispose() async {
    await manager.close();
    await canInput.close();
    await _hostCanProvider.close();
    await closableStorageProvider?.close();
  }

  static bool _environmentBool(
    Map<String, String> environment,
    String name,
    bool defaultValue,
  ) {
    final raw = environment[name];
    if (raw == null) return defaultValue;
    return switch (raw.trim().toLowerCase()) {
      '1' || 'true' || 'yes' || 'on' => true,
      '0' || 'false' || 'no' || 'off' => false,
      _ => throw ArgumentError.value(raw, name, 'Must be a boolean.'),
    };
  }

  static Directory _resolvePluginDirectory(
    List<String> arguments,
    Map<String, String> environment,
  ) {
    String? explicit = environment['VELOCE_PLUGIN_DIR'];
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument.startsWith('--plugins=')) {
        explicit = argument.substring('--plugins='.length);
      } else if (argument == '--plugins' && index + 1 < arguments.length) {
        explicit = arguments[++index];
      }
    }
    if (explicit != null && explicit.isNotEmpty) {
      return Directory(explicit).absolute;
    }

    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final candidates = [
      Directory('${Directory.current.path}${Platform.pathSeparator}plugins'),
      Directory(
        '${Directory.current.path}${Platform.pathSeparator}..'
        '${Platform.pathSeparator}..${Platform.pathSeparator}plugins',
      ),
      Directory('${executableDirectory.path}${Platform.pathSeparator}plugins'),
    ];
    return candidates
        .firstWhere(
          (directory) => directory.existsSync(),
          orElse: () => candidates.first,
        )
        .absolute;
  }
}
