import '../callbacks/plugin_callback_registry.dart';
import '../errors/plugin_exception.dart';
import '../values/structured_value.dart';
import 'plugin_ui_node.dart';

typedef PluginUiCallbackResolver = PluginCallbackRef Function(int token);

/// Strict decoder for the versioned Lua UI table format.
///
/// Unknown fields and implicit conversions are rejected so expanding the DSL
/// remains an explicit API-version decision.
final class PluginUiNodeCodec {
  const PluginUiNodeCodec({
    PluginUiValidator validator = const PluginUiValidator(),
  }) : _validator = validator;

  final PluginUiValidator _validator;

  PluginUiNode decode(
    StructuredValue value, {
    required String pluginId,
    required PluginUiCallbackResolver resolveCallback,
  }) {
    final decoder = _UiDecoder(
      pluginId: pluginId,
      resolveCallback: resolveCallback,
    );
    final node = decoder.node(value, r'$');
    _validator.validate(node, pluginId: pluginId);
    return node;
  }
}

final class _UiDecoder {
  const _UiDecoder({required this.pluginId, required this.resolveCallback});

  final String pluginId;
  final PluginUiCallbackResolver resolveCallback;

  PluginUiNode node(Object? raw, String path) {
    final map = _map(raw, path);
    final type = _required<String>(map, 'type', path);
    return switch (type) {
      'text' => _text(map, path),
      'icon' => _icon(map, path),
      'row' => _row(map, path),
      'column' => _column(map, path),
      'container' => _container(map, path),
      'button' => _button(map, path),
      'switch' => _switch(map, path),
      'slider' => _slider(map, path),
      'spacer' => _spacer(map, path),
      'list' => _list(map, path),
      'card' => _card(map, path),
      _ => _fail('Unknown UI node type "$type" at $path.'),
    };
  }

  PluginTextNode _text(Map<String, Object?> map, String path) {
    _fields(map, const {
      'type',
      'text',
      'font_size',
      'bold',
      'color',
      'alignment',
    }, path);
    return PluginTextNode(
      _required<String>(map, 'text', path),
      fontSize: _optionalNumber(map, 'font_size', path),
      bold: _optional<bool>(map, 'bold', path) ?? false,
      colorArgb: _optionalColor(map, path),
      alignment: _textAlignment(map['alignment'], '$path.alignment'),
    );
  }

  PluginIconNode _icon(Map<String, Object?> map, String path) {
    _fields(map, const {'type', 'name', 'size', 'color'}, path);
    return PluginIconNode(
      _required<String>(map, 'name', path),
      size: _optionalNumber(map, 'size', path),
      colorArgb: _optionalColor(map, path),
    );
  }

  PluginRowNode _row(Map<String, Object?> map, String path) {
    _axisFields(map, path);
    return PluginRowNode(
      _children(map, path),
      mainAxisAlignment: _mainAlignment(
        map['main_axis_alignment'],
        '$path.main_axis_alignment',
      ),
      crossAxisAlignment: _crossAlignment(
        map['cross_axis_alignment'],
        '$path.cross_axis_alignment',
      ),
      spacing: _optionalNumber(map, 'spacing', path) ?? 0,
    );
  }

  PluginColumnNode _column(Map<String, Object?> map, String path) {
    _axisFields(map, path);
    return PluginColumnNode(
      _children(map, path),
      mainAxisAlignment: _mainAlignment(
        map['main_axis_alignment'],
        '$path.main_axis_alignment',
      ),
      crossAxisAlignment: _crossAlignment(
        map['cross_axis_alignment'],
        '$path.cross_axis_alignment',
      ),
      spacing: _optionalNumber(map, 'spacing', path) ?? 0,
    );
  }

  void _axisFields(Map<String, Object?> map, String path) =>
      _fields(map, const {
        'type',
        'children',
        'main_axis_alignment',
        'cross_axis_alignment',
        'spacing',
      }, path);

  PluginContainerNode _container(Map<String, Object?> map, String path) {
    _fields(map, const {
      'type',
      'child',
      'padding',
      'width',
      'height',
      'color',
      'alignment',
    }, path);
    return PluginContainerNode(
      child: map['child'] == null ? null : node(map['child'], '$path.child'),
      padding: _padding(map['padding'], '$path.padding'),
      width: _optionalNumber(map, 'width', path),
      height: _optionalNumber(map, 'height', path),
      colorArgb: _optionalColor(map, path),
      alignment: _containerAlignment(map['alignment'], '$path.alignment'),
    );
  }

  PluginButtonNode _button(Map<String, Object?> map, String path) {
    _fields(map, const {
      'type',
      'text',
      'callback',
      'enabled',
      'icon_name',
    }, path);
    return PluginButtonNode(
      text: _required<String>(map, 'text', path),
      onPressed: _callback(map, path),
      enabled: _optional<bool>(map, 'enabled', path) ?? true,
      iconName: _optional<String>(map, 'icon_name', path),
    );
  }

  PluginSwitchNode _switch(Map<String, Object?> map, String path) {
    _fields(map, const {'type', 'value', 'callback', 'label', 'enabled'}, path);
    return PluginSwitchNode(
      value: _required<bool>(map, 'value', path),
      onChanged: _callback(map, path),
      label: _optional<String>(map, 'label', path),
      enabled: _optional<bool>(map, 'enabled', path) ?? true,
    );
  }

  PluginSliderNode _slider(Map<String, Object?> map, String path) {
    _fields(map, const {
      'type',
      'value',
      'min',
      'max',
      'divisions',
      'label',
      'callback',
      'enabled',
    }, path);
    return PluginSliderNode(
      value: _requiredNumber(map, 'value', path),
      min: _optionalNumber(map, 'min', path) ?? 0,
      max: _optionalNumber(map, 'max', path) ?? 1,
      divisions: _optional<int>(map, 'divisions', path),
      label: _optional<String>(map, 'label', path),
      onChanged: _callback(map, path),
      enabled: _optional<bool>(map, 'enabled', path) ?? true,
    );
  }

  PluginSpacerNode _spacer(Map<String, Object?> map, String path) {
    _fields(map, const {'type', 'flex'}, path);
    return PluginSpacerNode(flex: _optional<int>(map, 'flex', path) ?? 1);
  }

  PluginListNode _list(Map<String, Object?> map, String path) {
    _fields(map, const {'type', 'children', 'direction', 'spacing'}, path);
    return PluginListNode(
      _children(map, path),
      direction: _listDirection(map['direction'], '$path.direction'),
      spacing: _optionalNumber(map, 'spacing', path) ?? 0,
    );
  }

  PluginCardNode _card(Map<String, Object?> map, String path) {
    _fields(map, const {'type', 'child', 'padding', 'color'}, path);
    return PluginCardNode(
      child: node(_required<Object>(map, 'child', path), '$path.child'),
      padding: _padding(map['padding'], '$path.padding'),
      colorArgb: _optionalColor(map, path),
    );
  }

  List<PluginUiNode> _children(Map<String, Object?> map, String path) {
    final value = map['children'];
    final raw = value is Map<Object?, Object?> && value.isEmpty
        ? const <Object?>[]
        : _required<List<Object?>>(map, 'children', path);
    return List.unmodifiable([
      for (var index = 0; index < raw.length; index++)
        node(raw[index], '$path.children[$index]'),
    ]);
  }

  PluginCallbackRef _callback(Map<String, Object?> map, String path) {
    final token = _required<int>(map, 'callback', path);
    try {
      return resolveCallback(token);
    } on PluginException {
      rethrow;
    } catch (error, stackTrace) {
      throw PluginApiException(
        'Unknown UI callback token $token at $path.callback.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  PluginEdgeInsets _padding(Object? value, String path) {
    if (value == null) return const PluginEdgeInsets.all(0);
    if (value is num) return PluginEdgeInsets.all(value.toDouble());
    final map = _map(value, path);
    _fields(map, const {
      'all',
      'horizontal',
      'vertical',
      'left',
      'top',
      'right',
      'bottom',
    }, path);
    if (map.containsKey('all')) {
      if (map.length != 1) {
        _fail('$path.all cannot be combined with other padding fields.');
      }
      return PluginEdgeInsets.all(_number(map['all'], '$path.all'));
    }
    final horizontal = _numberOr(map['horizontal'], '$path.horizontal', 0);
    final vertical = _numberOr(map['vertical'], '$path.vertical', 0);
    return PluginEdgeInsets.only(
      left: _numberOr(map['left'], '$path.left', horizontal),
      top: _numberOr(map['top'], '$path.top', vertical),
      right: _numberOr(map['right'], '$path.right', horizontal),
      bottom: _numberOr(map['bottom'], '$path.bottom', vertical),
    );
  }

  PluginMainAxisAlignment _mainAlignment(Object? value, String path) =>
      switch (value) {
        null || 'start' => PluginMainAxisAlignment.start,
        'center' => PluginMainAxisAlignment.center,
        'end' => PluginMainAxisAlignment.end,
        'space_between' => PluginMainAxisAlignment.spaceBetween,
        'space_around' => PluginMainAxisAlignment.spaceAround,
        _ => _fail('Invalid main-axis alignment at $path.'),
      };

  PluginCrossAxisAlignment _crossAlignment(Object? value, String path) =>
      switch (value) {
        null || 'center' => PluginCrossAxisAlignment.center,
        'start' => PluginCrossAxisAlignment.start,
        'end' => PluginCrossAxisAlignment.end,
        'stretch' => PluginCrossAxisAlignment.stretch,
        _ => _fail('Invalid cross-axis alignment at $path.'),
      };

  PluginTextAlignment _textAlignment(Object? value, String path) =>
      switch (value) {
        null || 'start' => PluginTextAlignment.start,
        'center' => PluginTextAlignment.center,
        'end' => PluginTextAlignment.end,
        _ => _fail('Invalid text alignment at $path.'),
      };

  PluginContainerAlignment _containerAlignment(Object? value, String path) =>
      switch (value) {
        null || 'center' => PluginContainerAlignment.center,
        'top_start' => PluginContainerAlignment.topStart,
        'top_center' => PluginContainerAlignment.topCenter,
        'top_end' => PluginContainerAlignment.topEnd,
        'center_start' => PluginContainerAlignment.centerStart,
        'center_end' => PluginContainerAlignment.centerEnd,
        'bottom_start' => PluginContainerAlignment.bottomStart,
        'bottom_center' => PluginContainerAlignment.bottomCenter,
        'bottom_end' => PluginContainerAlignment.bottomEnd,
        _ => _fail('Invalid container alignment at $path.'),
      };

  PluginListDirection _listDirection(Object? value, String path) =>
      switch (value) {
        null || 'vertical' => PluginListDirection.vertical,
        'horizontal' => PluginListDirection.horizontal,
        _ => _fail('Invalid list direction at $path.'),
      };

  int? _optionalColor(Map<String, Object?> map, String path) {
    final value = map['color'];
    if (value == null && !map.containsKey('color')) return null;
    if (value is! int) _fail('$path.color must be an integer ARGB value.');
    return value;
  }

  double _requiredNumber(Map<String, Object?> map, String key, String path) {
    if (!map.containsKey(key)) _fail('$path.$key is required.');
    return _number(map[key], '$path.$key');
  }

  double? _optionalNumber(Map<String, Object?> map, String key, String path) {
    if (!map.containsKey(key)) return null;
    return _number(map[key], '$path.$key');
  }

  double _numberOr(Object? value, String path, double fallback) =>
      value == null ? fallback : _number(value, path);

  double _number(Object? value, String path) {
    if (value is! num || !value.toDouble().isFinite) {
      _fail('$path must be a finite number.');
    }
    return value.toDouble();
  }

  T _required<T>(Map<String, Object?> map, String key, String path) {
    if (!map.containsKey(key) || map[key] is! T) {
      _fail('$path.$key is required and must be $T.');
    }
    return map[key]! as T;
  }

  T? _optional<T>(Map<String, Object?> map, String key, String path) {
    if (!map.containsKey(key)) return null;
    final value = map[key];
    if (value is! T) _fail('$path.$key must be $T.');
    return value;
  }

  Map<String, Object?> _map(Object? value, String path) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      _fail('$path must be a string-keyed UI node map.');
    }
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries) entry.key! as String: entry.value,
    });
  }

  void _fields(Map<String, Object?> map, Set<String> allowed, String path) {
    final unknown = map.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      _fail('Unknown UI fields at $path: ${unknown.join(', ')}.');
    }
  }

  Never _fail(String message) =>
      throw PluginApiException(message, pluginId: pluginId);
}
