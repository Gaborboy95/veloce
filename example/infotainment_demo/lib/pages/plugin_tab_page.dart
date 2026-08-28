import 'package:flutter/material.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:ivi_lua_flutter/ivi_lua_flutter.dart';

final class PluginTabPage extends StatelessWidget {
  const PluginTabPage({
    super.key,
    required this.tab,
    required this.widgetBuilder,
  });

  final PluginTab tab;
  final PluginWidgetBuilder widgetBuilder;

  @override
  Widget build(BuildContext context) {
    final content = tab.content;
    if (content == null) {
      return const Center(child: Text('Dynamic render callback unavailable.'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: widgetBuilder.build(content, pluginId: tab.pluginId),
    );
  }
}
