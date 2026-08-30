import '../callbacks/plugin_callback_registry.dart';
import '../errors/plugin_exception.dart';

enum PluginMainAxisAlignment { start, center, end, spaceBetween, spaceAround }

enum PluginCrossAxisAlignment { start, center, end, stretch }

enum PluginTextAlignment { start, center, end }

enum PluginContainerAlignment {
  topStart,
  topCenter,
  topEnd,
  centerStart,
  center,
  centerEnd,
  bottomStart,
  bottomCenter,
  bottomEnd,
}

enum PluginListDirection { vertical, horizontal }

final class PluginEdgeInsets {
  const PluginEdgeInsets.all(double value)
    : left = value,
      top = value,
      right = value,
      bottom = value;

  const PluginEdgeInsets.symmetric({double horizontal = 0, double vertical = 0})
    : left = horizontal,
      top = vertical,
      right = horizontal,
      bottom = vertical;

  const PluginEdgeInsets.only({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// Safe, Flutter-independent intermediate UI nodes.
sealed class PluginUiNode {
  const PluginUiNode();
}

final class PluginTextNode extends PluginUiNode {
  const PluginTextNode(
    this.text, {
    this.fontSize,
    this.bold = false,
    this.colorArgb,
    this.alignment = PluginTextAlignment.start,
  });

  final String text;
  final double? fontSize;
  final bool bold;
  final int? colorArgb;
  final PluginTextAlignment alignment;
}

final class PluginIconNode extends PluginUiNode {
  const PluginIconNode(this.name, {this.size, this.colorArgb});

  final String name;
  final double? size;
  final int? colorArgb;
}

final class PluginRowNode extends PluginUiNode {
  PluginRowNode(
    Iterable<PluginUiNode> children, {
    this.mainAxisAlignment = PluginMainAxisAlignment.start,
    this.crossAxisAlignment = PluginCrossAxisAlignment.center,
    this.spacing = 0,
  }) : children = List.unmodifiable(children);

  final List<PluginUiNode> children;
  final PluginMainAxisAlignment mainAxisAlignment;
  final PluginCrossAxisAlignment crossAxisAlignment;
  final double spacing;
}

final class PluginColumnNode extends PluginUiNode {
  PluginColumnNode(
    Iterable<PluginUiNode> children, {
    this.mainAxisAlignment = PluginMainAxisAlignment.start,
    this.crossAxisAlignment = PluginCrossAxisAlignment.center,
    this.spacing = 0,
  }) : children = List.unmodifiable(children);

  final List<PluginUiNode> children;
  final PluginMainAxisAlignment mainAxisAlignment;
  final PluginCrossAxisAlignment crossAxisAlignment;
  final double spacing;
}

final class PluginContainerNode extends PluginUiNode {
  const PluginContainerNode({
    this.child,
    this.padding = const PluginEdgeInsets.all(0),
    this.width,
    this.height,
    this.colorArgb,
    this.alignment = PluginContainerAlignment.center,
  });

  final PluginUiNode? child;
  final PluginEdgeInsets padding;
  final double? width;
  final double? height;
  final int? colorArgb;
  final PluginContainerAlignment alignment;
}

final class PluginButtonNode extends PluginUiNode {
  const PluginButtonNode({
    required this.text,
    required this.onPressed,
    this.enabled = true,
    this.iconName,
  });

  final String text;
  final PluginCallbackRef onPressed;
  final bool enabled;
  final String? iconName;
}

final class PluginSwitchNode extends PluginUiNode {
  const PluginSwitchNode({
    required this.value,
    required this.onChanged,
    this.label,
    this.enabled = true,
  });

  final bool value;
  final PluginCallbackRef onChanged;
  final String? label;
  final bool enabled;
}

final class PluginSliderNode extends PluginUiNode {
  const PluginSliderNode({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.enabled = true,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final PluginCallbackRef onChanged;
  final bool enabled;
}

final class PluginSpacerNode extends PluginUiNode {
  const PluginSpacerNode({this.flex = 1});

  final int flex;
}

final class PluginListNode extends PluginUiNode {
  PluginListNode(
    Iterable<PluginUiNode> children, {
    this.direction = PluginListDirection.vertical,
    this.spacing = 0,
  }) : children = List.unmodifiable(children);

  final List<PluginUiNode> children;
  final PluginListDirection direction;
  final double spacing;
}

final class PluginCardNode extends PluginUiNode {
  const PluginCardNode({
    required this.child,
    this.padding = const PluginEdgeInsets.all(12),
    this.colorArgb,
  });

  final PluginUiNode child;
  final PluginEdgeInsets padding;
  final int? colorArgb;
}

/// Rejects oversized or malformed UI trees before Flutter sees them.
final class PluginUiValidator {
  const PluginUiValidator({
    this.maxDepth = 32,
    this.maxNodes = 1000,
    this.maxChildrenPerNode = 200,
    this.maxTextLength = 4096,
  });

  final int maxDepth;
  final int maxNodes;
  final int maxChildrenPerNode;
  final int maxTextLength;

  void validate(PluginUiNode root, {required String pluginId}) {
    var nodes = 0;

    void visit(PluginUiNode node, int depth) {
      nodes++;
      if (nodes > maxNodes) _fail('UI tree exceeds $maxNodes nodes.', pluginId);
      if (depth > maxDepth) _fail('UI tree exceeds depth $maxDepth.', pluginId);
      switch (node) {
        case PluginTextNode():
          _text(node.text, pluginId);
          _positiveOptional(node.fontSize, 'fontSize', pluginId);
          _color(node.colorArgb, pluginId);
        case PluginIconNode():
          _name(node.name, 'icon name', pluginId);
          _positiveOptional(node.size, 'icon size', pluginId);
          _color(node.colorArgb, pluginId);
        case PluginRowNode():
          _children(node.children, depth, pluginId, visit);
          _nonNegative(node.spacing, 'spacing', pluginId);
        case PluginColumnNode():
          _children(node.children, depth, pluginId, visit);
          _nonNegative(node.spacing, 'spacing', pluginId);
        case PluginContainerNode():
          _dimensions(node.width, node.height, pluginId);
          _insets(node.padding, pluginId);
          _color(node.colorArgb, pluginId);
          if (node.child case final child?) visit(child, depth + 1);
        case PluginButtonNode():
          _text(node.text, pluginId);
          _callback(node.onPressed, pluginId);
          if (node.iconName case final name?) {
            _name(name, 'icon name', pluginId);
          }
        case PluginSwitchNode():
          if (node.label case final label?) _text(label, pluginId);
          _callback(node.onChanged, pluginId);
        case PluginSliderNode():
          if (!node.value.isFinite ||
              !node.min.isFinite ||
              !node.max.isFinite ||
              node.min >= node.max ||
              node.value < node.min ||
              node.value > node.max) {
            _fail('Invalid slider range or value.', pluginId);
          }
          if (node.divisions case final divisions? when divisions <= 0) {
            _fail('Slider divisions must be positive.', pluginId);
          }
          if (node.label case final label?) _text(label, pluginId);
          _callback(node.onChanged, pluginId);
        case PluginSpacerNode():
          if (node.flex <= 0) _fail('Spacer flex must be positive.', pluginId);
        case PluginListNode():
          _children(node.children, depth, pluginId, visit);
          _nonNegative(node.spacing, 'spacing', pluginId);
        case PluginCardNode():
          _insets(node.padding, pluginId);
          _color(node.colorArgb, pluginId);
          visit(node.child, depth + 1);
      }
    }

    visit(root, 0);
  }

  void _children(
    List<PluginUiNode> children,
    int depth,
    String pluginId,
    void Function(PluginUiNode, int) visit,
  ) {
    if (children.length > maxChildrenPerNode) {
      _fail('A UI node exceeds $maxChildrenPerNode children.', pluginId);
    }
    for (final child in children) {
      visit(child, depth + 1);
    }
  }

  void _text(String value, String pluginId) {
    if (value.length > maxTextLength) {
      _fail('UI text exceeds $maxTextLength characters.', pluginId);
    }
  }

  void _name(String value, String field, String pluginId) {
    if (value.isEmpty ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
      _fail('Invalid $field.', pluginId);
    }
  }

  void _callback(PluginCallbackRef reference, String pluginId) {
    if (reference.pluginId != pluginId) {
      _fail('UI callback belongs to another plugin.', pluginId);
    }
  }

  void _dimensions(double? width, double? height, String pluginId) {
    _positiveOptional(width, 'width', pluginId);
    _positiveOptional(height, 'height', pluginId);
  }

  void _positiveOptional(double? value, String field, String pluginId) {
    if (value != null && (!value.isFinite || value <= 0)) {
      _fail('$field must be finite and positive.', pluginId);
    }
  }

  void _nonNegative(double value, String field, String pluginId) {
    if (!value.isFinite || value < 0) {
      _fail('$field must be finite and non-negative.', pluginId);
    }
  }

  void _insets(PluginEdgeInsets insets, String pluginId) {
    for (final value in [
      insets.left,
      insets.top,
      insets.right,
      insets.bottom,
    ]) {
      _nonNegative(value, 'padding', pluginId);
    }
  }

  void _color(int? value, String pluginId) {
    if (value != null && (value < 0 || value > 0xffffffff)) {
      _fail('ARGB color must be an unsigned 32-bit integer.', pluginId);
    }
  }

  Never _fail(String message, String pluginId) =>
      throw PluginApiException(message, pluginId: pluginId);
}
