import 'dart:async';

import 'package:flutter/material.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_flutter/veloce_lua_flutter.dart';

import 'demo_runtime.dart';
import 'pages/developer_console_page.dart';
import 'pages/home_page.dart';
import 'pages/plugin_tab_page.dart';
import 'pages/plugins_page.dart';

final class InfotainmentDemo extends StatefulWidget {
  const InfotainmentDemo({super.key, required this.runtime});

  final DemoRuntime runtime;

  @override
  State<InfotainmentDemo> createState() => _InfotainmentDemoState();
}

final class _InfotainmentDemoState extends State<InfotainmentDemo> {
  late final PluginWidgetBuilder _widgetBuilder;
  StreamSubscription<List<PluginTab>>? _tabsSubscription;
  StreamSubscription<List<PluginRecord>>? _pluginsSubscription;
  List<PluginTab> _pluginTabs = const [];
  var _selectedIndex = 0;

  PluginManager get manager => widget.runtime.manager;

  @override
  void initState() {
    super.initState();
    _widgetBuilder = PluginWidgetBuilder(
      callbackInvoker: manager.invokeCallback,
      onError: (error, _) => manager.logManager
          .logger('host.ui')
          .error('Plugin UI callback failed: $error'),
    );
    _pluginTabs = manager.uiRegistry.currentTabs;
    _tabsSubscription = manager.uiRegistry.tabs.listen((tabs) {
      if (!mounted) return;
      setState(() {
        _pluginTabs = tabs;
        final maximum = 2 + tabs.length;
        if (_selectedIndex > maximum) _selectedIndex = 0;
      });
    });
    _pluginsSubscription = manager.plugins.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_tabsSubscription?.cancel());
    unawaited(_pluginsSubscription?.cancel());
    unawaited(widget.runtime.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationRailDestination>[
      const NavigationRailDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: Text('Home'),
      ),
      const NavigationRailDestination(
        icon: Icon(Icons.extension_outlined),
        selectedIcon: Icon(Icons.extension),
        label: Text('Plugins'),
      ),
      const NavigationRailDestination(
        icon: Icon(Icons.terminal_outlined),
        selectedIcon: Icon(Icons.terminal),
        label: Text('Developer Console'),
      ),
      for (final tab in _pluginTabs)
        NavigationRailDestination(
          icon: const Icon(Icons.dashboard_outlined),
          selectedIcon: const Icon(Icons.dashboard),
          label: Text(tab.title),
        ),
    ];

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Veloce Lua Runtime',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff00a6a6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Veloce Lua Runtime'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${manager.currentPlugins.where((item) => item.state == PluginState.running).length} plugins running',
                ),
              ),
            ),
          ],
        ),
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1100,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (value) {
                setState(() => _selectedIndex = value);
              },
              destinations: destinations,
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _selectedPage()),
          ],
        ),
      ),
    );
  }

  Widget _selectedPage() => switch (_selectedIndex) {
    0 => HomePage(runtime: widget.runtime),
    1 => PluginsPage(manager: manager),
    2 => DeveloperConsolePage(logManager: manager.logManager),
    _ => PluginTabPage(
      tab: _pluginTabs[_selectedIndex - 3],
      widgetBuilder: _widgetBuilder,
    ),
  };
}

final class DemoStartupFailure extends StatelessWidget {
  const DemoStartupFailure({
    super.key,
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The Veloce Lua demo could not start',
                  style: TextStyle(fontSize: 28),
                ),
                const SizedBox(height: 16),
                SelectableText(error.toString()),
                const SizedBox(height: 12),
                SelectableText(
                  stackTrace.toString(),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
