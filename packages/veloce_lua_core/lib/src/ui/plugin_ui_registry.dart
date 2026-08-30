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

abstract final class PluginUiExtensionPoints {
  static const settingsPages = 'ui.settings.pages';
  static const quickControls = 'ui.quick_controls';
  static const statusWidgets = 'ui.status.widgets';
  static const notifications = 'ui.notifications';

  static const all = {
    settingsPages,
    quickControls,
    statusWidgets,
    notifications,
  };
}

/// Declarative contribution to a non-tab Flutter extension point.
final class PluginUiContribution {
  const PluginUiContribution({
    required this.extensionPoint,
    required this.pluginId,
    required this.id,
    required this.content,
    this.title,
    this.iconName,
  });

  final String extensionPoint;
  final String pluginId;
  final String id;
  final String? title;
  final String? iconName;
  final PluginUiNode content;
}

/// Typed tab facade over the generic extension registry.
final class PluginUiRegistry {
  PluginUiRegistry({
    PluginExtensionRegistry? extensions,
    PluginUiValidator validator = const PluginUiValidator(),
  }) : extensions = extensions ?? PluginExtensionRegistry(),
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

  Stream<List<PluginTab>> get tabs => extensions
      .watch<PluginTab>(tabsExtensionPoint)
      .map(
        (items) =>
            items.map((extension) => extension.value).toList(growable: false),
      );

  List<PluginUiContribution> currentContributions(String extensionPoint) =>
      extensions
          .extensions<PluginUiContribution>(extensionPoint)
          .map((extension) => extension.value)
          .toList(growable: false);

  Stream<List<PluginUiContribution>> contributions(String extensionPoint) =>
      extensions
          .watch<PluginUiContribution>(extensionPoint)
          .map(
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

  void registerContribution(PluginUiContribution contribution) {
    _validateContribution(contribution);
    extensions.register(
      PluginExtension<PluginUiContribution>(
        extensionPoint: contribution.extensionPoint,
        pluginId: contribution.pluginId,
        id: contribution.id,
        value: contribution,
      ),
    );
  }

  void replacePluginContributions(
    String pluginId,
    String extensionPoint,
    Iterable<PluginUiContribution> contributions,
  ) {
    final replacements = contributions.toList(growable: false);
    for (final contribution in replacements) {
      if (contribution.pluginId != pluginId ||
          contribution.extensionPoint != extensionPoint) {
        throw PluginApiException(
          'Cannot register a UI contribution for another owner or point.',
          pluginId: pluginId,
        );
      }
      _validateContribution(contribution);
    }
    extensions.replaceForPlugin<PluginUiContribution>(
      extensionPoint: extensionPoint,
      pluginId: pluginId,
      extensions: replacements.map(
        (item) => PluginExtension<PluginUiContribution>(
          extensionPoint: extensionPoint,
          pluginId: pluginId,
          id: item.id,
          value: item,
        ),
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

  void _validateContribution(PluginUiContribution contribution) {
    if (!PluginUiExtensionPoints.all.contains(contribution.extensionPoint) ||
        contribution.pluginId.trim().isEmpty ||
        contribution.id.isEmpty ||
        contribution.id.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(contribution.id) ||
        (contribution.title?.length ?? 0) > 128 ||
        (contribution.iconName?.length ?? 0) > 128) {
      throw PluginApiException(
        'Invalid plugin UI contribution metadata.',
        pluginId: contribution.pluginId,
      );
    }
    _validator.validate(contribution.content, pluginId: contribution.pluginId);
  }
}
