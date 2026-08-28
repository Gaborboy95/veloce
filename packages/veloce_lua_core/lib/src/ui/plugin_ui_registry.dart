import 'dart:async';

import '../callbacks/plugin_callback_registry.dart';
import '../extensions/plugin_extension_registry.dart';
import '../errors/plugin_exception.dart';
import 'plugin_ui_node.dart';

final class PluginTab {
  PluginTab({
    required this.pluginId,
    required this.id,
    required this.title,
    this.iconName,
    this.content,
    this.renderCallback,
  }) {
    if ((content == null) == (renderCallback == null)) {
      throw ArgumentError(
        'A plugin tab must have exactly one content or renderCallback.',
      );
    }
  }

  final String pluginId;
  final String id;
  final String title;
  final String? iconName;
  final PluginUiNode? content;
  final PluginCallbackRef? renderCallback;
}

/// Typed tab facade over the generic extension registry.
final class PluginUiRegistry {
  PluginUiRegistry({
    PluginExtensionRegistry? extensions,
    PluginUiValidator validator = const PluginUiValidator(),
  })  : extensions = extensions ?? PluginExtensionRegistry(),
        _ownsExtensions = extensions == null,
        _validator = validator;

  static const tabsExtensionPoint = 'ui.tabs';

  final PluginExtensionRegistry extensions;
  final bool _ownsExtensions;
  final PluginUiValidator _validator;

  List<PluginTab> get currentTabs => extensions
      .extensions<PluginTab>(tabsExtensionPoint)
      .map((extension) => extension.value)
      .toList(growable: false);

  Stream<List<PluginTab>> get tabs =>
      extensions.watch<PluginTab>(tabsExtensionPoint).map(
            (items) => items
                .map((extension) => extension.value)
                .toList(growable: false),
          );

  void registerTab(PluginTab tab) {
    _validateTab(tab);
    extensions.register(
      PluginExtension<PluginTab>(
        extensionPoint: tabsExtensionPoint,
        pluginId: tab.pluginId,
        id: tab.id,
        value: tab,
      ),
    );
  }

  /// Atomically swaps the complete tab set for a plugin after validation.
  void replacePluginTabs(String pluginId, Iterable<PluginTab> tabs) {
    final replacements = tabs.toList(growable: false);
    for (final tab in replacements) {
      if (tab.pluginId != pluginId) {
        throw PluginApiException(
          'Cannot register a tab owned by another plugin.',
          pluginId: pluginId,
        );
      }
      _validateTab(tab);
    }
    extensions.replaceForPlugin<PluginTab>(
      extensionPoint: tabsExtensionPoint,
      pluginId: pluginId,
      extensions: replacements.map(
        (tab) => PluginExtension<PluginTab>(
          extensionPoint: tabsExtensionPoint,
          pluginId: pluginId,
          id: tab.id,
          value: tab,
        ),
      ),
    );
  }

  void unregisterPlugin(String pluginId) =>
      extensions.unregisterPlugin(pluginId);

  Future<void> close() async {
    if (_ownsExtensions) await extensions.close();
  }

  void _validateTab(PluginTab tab) {
    if (tab.pluginId.trim().isEmpty ||
        tab.id.isEmpty ||
        tab.id.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(tab.id) ||
        tab.title.isEmpty ||
        tab.title.length > 128) {
      throw PluginApiException(
        'Invalid plugin tab metadata.',
        pluginId: tab.pluginId,
      );
    }
    if (tab.iconName case final icon?
        when icon.isEmpty ||
            icon.length > 128 ||
            !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(icon)) {
      throw PluginApiException(
        'Invalid plugin tab icon.',
        pluginId: tab.pluginId,
      );
    }
    if (tab.content case final content?) {
      _validator.validate(content, pluginId: tab.pluginId);
    }
    if (tab.renderCallback case final callback?
        when callback.pluginId != tab.pluginId) {
      throw PluginApiException(
        'Tab render callback belongs to another plugin.',
        pluginId: tab.pluginId,
      );
    }
  }
}
