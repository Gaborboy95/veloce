import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';

final class DeveloperConsolePage extends StatefulWidget {
  const DeveloperConsolePage({super.key, required this.logManager});

  final PluginLogManager logManager;

  @override
  State<DeveloperConsolePage> createState() => _DeveloperConsolePageState();
}

final class _DeveloperConsolePageState extends State<DeveloperConsolePage> {
  StreamSubscription<PluginLogEvent>? _subscription;
  late List<PluginLogEvent> _events;

  @override
  void initState() {
    super.initState();
    _events = widget.logManager.recent;
    _subscription = widget.logManager.events.listen((_) {
      if (mounted) setState(() => _events = widget.logManager.recent);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Developer Console',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            TextButton.icon(
              onPressed: () {
                widget.logManager.clear();
                setState(() => _events = const []);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clear'),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: _events.isEmpty
            ? const Center(child: Text('No plugin logs yet.'))
            : ListView.builder(
                reverse: true,
                itemCount: _events.length,
                itemBuilder: (context, index) {
                  final event = _events[_events.length - index - 1];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      _icon(event.level),
                      color: _color(event.level),
                      size: 18,
                    ),
                    title: Text(
                      event.message,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '${event.pluginId}  ${event.timestamp.toLocal().toIso8601String()}',
                    ),
                  );
                },
              ),
      ),
    ],
  );

  static IconData _icon(PluginLogLevel level) => switch (level) {
    PluginLogLevel.debug => Icons.bug_report_outlined,
    PluginLogLevel.info => Icons.info_outline,
    PluginLogLevel.warning => Icons.warning_amber,
    PluginLogLevel.error => Icons.error_outline,
  };

  static Color _color(PluginLogLevel level) => switch (level) {
    PluginLogLevel.debug => Colors.blueGrey,
    PluginLogLevel.info => Colors.blue,
    PluginLogLevel.warning => Colors.amber,
    PluginLogLevel.error => Colors.red,
  };
}
