import 'package:flutter/material.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

final class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key, required this.manager});

  final PluginManager manager;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<PluginRecord>>(
    stream: manager.plugins,
    initialData: manager.currentPlugins,
    builder: (context, snapshot) {
      final plugins = snapshot.data ?? const [];
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Plugins', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          if (plugins.isEmpty)
            const Card(
              child: ListTile(
                title: Text('No valid plugins discovered'),
                subtitle: Text(
                  'Add a plugin directory containing manifest.json and main.lua.',
                ),
              ),
            ),
          for (final plugin in plugins)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PluginCard(manager: manager, record: plugin),
            ),
          for (final failure in manager.discoveryFailures)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(failure.directoryPath),
                subtitle: Text(failure.error.toString()),
              ),
            ),
        ],
      );
    },
  );
}

final class _PluginCard extends StatefulWidget {
  const _PluginCard({required this.manager, required this.record});

  final PluginManager manager;
  final PluginRecord record;

  @override
  State<_PluginCard> createState() => _PluginCardState();
}

final class _PluginCardState extends State<_PluginCard> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final manifest = record.manifest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        manifest.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text('${manifest.id}  •  ${manifest.version}'),
                    ],
                  ),
                ),
                _StateChip(state: record.state),
                const SizedBox(width: 12),
                Switch(
                  value: record.enabled,
                  onChanged: _busy
                      ? null
                      : (enabled) => _run(
                          () => widget.manager.setEnabled(manifest.id, enabled),
                        ),
                ),
                IconButton(
                  tooltip: 'Transactional reload',
                  onPressed: _busy || record.state != PluginState.running
                      ? null
                      : () => _run(
                          () => widget.manager.reloadPlugin(manifest.id),
                        ),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final permission in manifest.permissions)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(permission.name),
                  ),
              ],
            ),
            if (record.latestError case final error?) ...[
              const Divider(height: 24),
              Text(
                error.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (_luaTrace(error) case final trace?)
                SelectableText(
                  trace,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String? _luaTrace(PluginException error) => switch (error) {
    PluginLuaException() => error.luaStackTrace,
    PluginReloadException() => error.luaStackTrace,
    _ => null,
  };
}

final class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final PluginState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      PluginState.running => Colors.green,
      PluginState.failed => Theme.of(context).colorScheme.error,
      PluginState.loading ||
      PluginState.reloading ||
      PluginState.unloading => Colors.amber,
      _ => Colors.blueGrey,
    };
    return Chip(
      avatar: Icon(Icons.circle, size: 12, color: color),
      label: Text(state.name),
    );
  }
}
