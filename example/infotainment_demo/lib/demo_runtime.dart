import 'dart:io';

import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:ivi_lua_native/ivi_lua_native.dart';

final class DemoRuntime {
  DemoRuntime({
    required this.manager,
    required this.canProvider,
    required this.pluginDirectory,
  });

  final PluginManager manager;
  final InMemoryCanProvider canProvider;
  final Directory pluginDirectory;

  static Future<DemoRuntime> create(List<String> arguments) async {
    final pluginDirectory = _resolvePluginDirectory(arguments);
    final storageRoot = Directory(
      Platform.environment['IVI_PLUGIN_STORAGE'] ??
          '${Directory.current.path}${Platform.pathSeparator}.ivi_plugin_storage',
    );
    final canPolicy = ConfigurableCanAuthorizationPolicy()
      ..setGrant(
        'dev.example.can_decoder',
        CanAccessGrant(
          readFilters: [CanFilter(bus: 'comfort', id: 0x280, mask: 0x7ff)],
        ),
      )
      ..setGrant(
        'com.veloce.phaeton.gp3.comfort',
        CanAccessGrant(
          readFilters: [CanFilter(bus: 'comfort')],
        ),
      )
      ..setGrant(
        'com.veloce.phaeton.gp3.infotainment',
        CanAccessGrant(
          readFilters: [CanFilter(bus: 'infotainment')],
        ),
      );
    final canProvider = InMemoryCanProvider(writesEnabled: false);
    final nativePath = Platform.environment['IVI_LUA_LIBRARY'];
    final manager = PluginManager(
      pluginRoot: pluginDirectory,
      runtimeFactory: NativeLuaRuntimeFactory(
        resolver: DefaultNativeLuaLibraryResolver(libraryPath: nativePath),
      ),
      canProvider: canProvider,
      canAuthorizationPolicy: canPolicy,
      storageProvider: JsonPluginStorageProvider(rootDirectory: storageRoot),
    );
    await manager.discover();
    await manager.startWatching();
    return DemoRuntime(
      manager: manager,
      canProvider: canProvider,
      pluginDirectory: pluginDirectory,
    );
  }

  Future<void> dispose() async {
    await manager.close();
    await canProvider.close();
  }

  static Directory _resolvePluginDirectory(List<String> arguments) {
    String? explicit = Platform.environment['IVI_PLUGIN_DIR'];
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

