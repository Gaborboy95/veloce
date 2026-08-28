import 'dart:async';
import 'dart:io';

/// Coalesces editor save bursts into one plugin-directory change event.
final class PluginWatcher {
  PluginWatcher({
    required Directory pluginRoot,
    this.debounce = const Duration(milliseconds: 350),
  }) : _pluginRoot = pluginRoot.absolute;

  final Directory _pluginRoot;
  final Duration debounce;
  final StreamController<String> _changes = StreamController.broadcast();
  final Map<String, Timer> _timers = {};
  StreamSubscription<FileSystemEvent>? _subscription;

  Stream<String> get changes => _changes.stream;
  bool get isWatching => _subscription != null;

  Future<void> start() async {
    if (_subscription != null) return;
    if (!await _pluginRoot.exists()) await _pluginRoot.create(recursive: true);
    _subscription = _pluginRoot.watch(recursive: true).listen(
          _onEvent,
          onError: _changes.addError,
        );
  }

  void _onEvent(FileSystemEvent event) {
    final directory = pluginDirectoryFor(event.path);
    if (directory == null) return;
    _timers.remove(directory)?.cancel();
    _timers[directory] = Timer(debounce, () {
      _timers.remove(directory);
      if (!_changes.isClosed) _changes.add(directory);
    });
  }

  String? pluginDirectoryFor(String changedPath) {
    final rootPath = _withTrailingSeparator(_pluginRoot.path);
    final targetPath = File(changedPath).absolute.path;
    final normalizedRoot =
        Platform.isWindows ? rootPath.toLowerCase() : rootPath;
    final normalizedTarget =
        Platform.isWindows ? targetPath.toLowerCase() : targetPath;
    if (!normalizedTarget.startsWith(normalizedRoot)) return null;
    final relativePath = targetPath.substring(rootPath.length);
    if (relativePath.isEmpty) return null;
    final directoryName = relativePath.split(Platform.pathSeparator).first;
    if (directoryName.isEmpty) return null;
    return Directory('$rootPath$directoryName').absolute.path;
  }

  static String _withTrailingSeparator(String path) =>
      path.endsWith(Platform.pathSeparator)
          ? path
          : '$path${Platform.pathSeparator}';

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    await _changes.close();
  }
}
