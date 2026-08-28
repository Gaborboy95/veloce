import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';

/// Invokes a callback owned by a particular plugin runtime generation.
///
/// Arguments contain only Dart/Lua structured values. Flutter objects and
/// [BuildContext] are never passed across this boundary.
typedef PluginCallbackInvoker = Future<void> Function(
  PluginCallbackRef callback,
  List<Object?> arguments,
);

/// Receives a contained validation or callback error for diagnostics.
typedef PluginWidgetErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Converts validated, Flutter-independent plugin UI nodes into Material UI.
///
/// The builder validates the tree again at the Flutter boundary. Invalid trees
/// render a neutral placeholder, and callback failures are contained so a
/// stale Lua callback cannot escape through Flutter's gesture handlers.
final class PluginWidgetBuilder {
  PluginWidgetBuilder({
    required this.callbackInvoker,
    this.onError,
    this.validator = const PluginUiValidator(),
  });

  final PluginCallbackInvoker callbackInvoker;
  final PluginWidgetErrorHandler? onError;
  final PluginUiValidator validator;

  /// Builds [root] for [pluginId] without exposing Flutter context to Lua.
  Widget build(PluginUiNode root, {required String pluginId}) {
    try {
      validator.validate(root, pluginId: pluginId);
      return _buildNode(root, isFlexChild: false);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return const Center(child: Text('Plugin UI unavailable'));
    }
  }

  Widget _buildNode(PluginUiNode node, {required bool isFlexChild}) {
    return switch (node) {
      PluginTextNode() => Text(
        node.text,
        textAlign: _textAlignment(node.alignment),
        style: TextStyle(
          color: _color(node.colorArgb),
          fontSize: node.fontSize,
          fontWeight: node.bold ? FontWeight.bold : null,
        ),
      ),
      PluginIconNode() => Icon(
        _icon(node.name),
        size: node.size,
        color: _color(node.colorArgb),
      ),
      PluginRowNode() => Row(
        mainAxisAlignment: _mainAxisAlignment(node.mainAxisAlignment),
        crossAxisAlignment: _crossAxisAlignment(node.crossAxisAlignment),
        children: _withSpacing(
          node.children
              .map((child) => _buildNode(child, isFlexChild: true))
              .toList(growable: false),
          node.spacing,
          Axis.horizontal,
        ),
      ),
      PluginColumnNode() => Column(
        mainAxisAlignment: _mainAxisAlignment(node.mainAxisAlignment),
        crossAxisAlignment: _crossAxisAlignment(node.crossAxisAlignment),
        children: _withSpacing(
          node.children
              .map((child) => _buildNode(child, isFlexChild: true))
              .toList(growable: false),
          node.spacing,
          Axis.vertical,
        ),
      ),
      PluginContainerNode() => Container(
        width: node.width,
        height: node.height,
        padding: _edgeInsets(node.padding),
        alignment: _containerAlignment(node.alignment),
        color: _color(node.colorArgb),
        child: node.child == null
            ? null
            : _buildNode(node.child!, isFlexChild: false),
      ),
      PluginButtonNode() => _button(node),
      PluginSwitchNode() => _switch(node),
      PluginSliderNode() => Slider(
        value: node.value,
        min: node.min,
        max: node.max,
        divisions: node.divisions,
        label: node.label,
        onChanged: node.enabled
            ? (value) => _schedule(node.onChanged, <Object?>[value])
            : null,
      ),
      PluginSpacerNode() =>
        isFlexChild ? Spacer(flex: node.flex) : const SizedBox.shrink(),
      PluginListNode() => _list(node),
      PluginCardNode() => Card(
        color: _color(node.colorArgb),
        child: Padding(
          padding: _edgeInsets(node.padding),
          child: _buildNode(node.child, isFlexChild: false),
        ),
      ),
    };
  }

  Widget _button(PluginButtonNode node) {
    final onPressed = node.enabled
        ? () => _schedule(node.onPressed, const <Object?>[])
        : null;
    final iconName = node.iconName;
    if (iconName == null) {
      return ElevatedButton(onPressed: onPressed, child: Text(node.text));
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(_icon(iconName)),
      label: Text(node.text),
    );
  }

  Widget _switch(PluginSwitchNode node) {
    final onChanged = node.enabled
        ? (bool value) => _schedule(node.onChanged, <Object?>[value])
        : null;
    if (node.label case final label?) {
      return SwitchListTile(
        title: Text(label),
        value: node.value,
        onChanged: onChanged,
      );
    }
    return Switch(value: node.value, onChanged: onChanged);
  }

  Widget _list(PluginListNode node) {
    final axis = switch (node.direction) {
      PluginListDirection.vertical => Axis.vertical,
      PluginListDirection.horizontal => Axis.horizontal,
    };
    final children = _withSpacing(
      node.children
          .map((child) => _buildNode(child, isFlexChild: false))
          .toList(growable: false),
      node.spacing,
      axis,
    );

    // Core validation caps list length, so eager construction is bounded.
    // This also avoids nested viewport failures in loosely constrained Flexes.
    return SingleChildScrollView(
      scrollDirection: axis,
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  void _schedule(PluginCallbackRef callback, List<Object?> arguments) {
    unawaited(_invokeSafely(callback, List<Object?>.unmodifiable(arguments)));
  }

  Future<void> _invokeSafely(
    PluginCallbackRef callback,
    List<Object?> arguments,
  ) async {
    try {
      await callbackInvoker(callback, arguments);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    try {
      onError?.call(error, stackTrace);
    } catch (_) {
      // A diagnostic sink cannot turn a contained plugin error into a UI
      // failure.
    }
  }

  static List<Widget> _withSpacing(
    List<Widget> children,
    double spacing,
    Axis axis,
  ) {
    if (spacing == 0 || children.length < 2) return children;
    final separator = axis == Axis.horizontal
        ? SizedBox(width: spacing)
        : SizedBox(height: spacing);
    return <Widget>[
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) separator,
        children[index],
      ],
    ];
  }

  static Color? _color(int? argb) => argb == null ? null : Color(argb);

  static EdgeInsets _edgeInsets(PluginEdgeInsets value) =>
      EdgeInsets.fromLTRB(value.left, value.top, value.right, value.bottom);

  static TextAlign _textAlignment(PluginTextAlignment value) => switch (value) {
    PluginTextAlignment.start => TextAlign.start,
    PluginTextAlignment.center => TextAlign.center,
    PluginTextAlignment.end => TextAlign.end,
  };

  static MainAxisAlignment _mainAxisAlignment(PluginMainAxisAlignment value) =>
      switch (value) {
        PluginMainAxisAlignment.start => MainAxisAlignment.start,
        PluginMainAxisAlignment.center => MainAxisAlignment.center,
        PluginMainAxisAlignment.end => MainAxisAlignment.end,
        PluginMainAxisAlignment.spaceBetween => MainAxisAlignment.spaceBetween,
        PluginMainAxisAlignment.spaceAround => MainAxisAlignment.spaceAround,
      };

  static CrossAxisAlignment _crossAxisAlignment(
    PluginCrossAxisAlignment value,
  ) => switch (value) {
    PluginCrossAxisAlignment.start => CrossAxisAlignment.start,
    PluginCrossAxisAlignment.center => CrossAxisAlignment.center,
    PluginCrossAxisAlignment.end => CrossAxisAlignment.end,
    PluginCrossAxisAlignment.stretch => CrossAxisAlignment.stretch,
  };

  static Alignment _containerAlignment(PluginContainerAlignment value) =>
      switch (value) {
        PluginContainerAlignment.topStart => Alignment.topLeft,
        PluginContainerAlignment.topCenter => Alignment.topCenter,
        PluginContainerAlignment.topEnd => Alignment.topRight,
        PluginContainerAlignment.centerStart => Alignment.centerLeft,
        PluginContainerAlignment.center => Alignment.center,
        PluginContainerAlignment.centerEnd => Alignment.centerRight,
        PluginContainerAlignment.bottomStart => Alignment.bottomLeft,
        PluginContainerAlignment.bottomCenter => Alignment.bottomCenter,
        PluginContainerAlignment.bottomEnd => Alignment.bottomRight,
      };

  static IconData _icon(String name) =>
      _allowedIcons[name] ?? Icons.extension_outlined;

  static const Map<String, IconData> _allowedIcons = {
    'add': Icons.add,
    'remove': Icons.remove,
    'home': Icons.home,
    'settings': Icons.settings,
    'dashboard': Icons.dashboard,
    'directions_car': Icons.directions_car,
    'speed': Icons.speed,
    'thermostat': Icons.thermostat,
    'notifications': Icons.notifications,
    'info': Icons.info,
    'warning': Icons.warning,
    'error': Icons.error,
    'check': Icons.check,
    'close': Icons.close,
    'refresh': Icons.refresh,
    'play_arrow': Icons.play_arrow,
    'pause': Icons.pause,
    'menu': Icons.menu,
  };
}
