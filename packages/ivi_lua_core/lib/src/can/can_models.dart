import 'dart:typed_data';

/// A transport-level CAN/CAN-FD frame.
final class CanFrame {
  CanFrame({
    required this.bus,
    required this.id,
    required List<int> data,
    this.extended = false,
    this.timestampMicros,
  }) : _data = _validateAndCopyData(data) {
    _validateBus(bus);
    _validateIdentifier(id, extended: extended);
    if (timestampMicros case final value? when value < 0) {
      throw ArgumentError.value(
        timestampMicros,
        'timestampMicros',
        'Must not be negative',
      );
    }
  }

  final String bus;
  final int id;
  final Uint8List _data;
  final bool extended;
  final int? timestampMicros;

  /// A defensive copy; callers cannot mutate a frame after validation.
  Uint8List get data => Uint8List.fromList(_data);

  int get length => _data.length;

  Map<String, Object?> toStructuredValue() => {
        'bus': bus,
        'id': id,
        'data': List<int>.unmodifiable(_data),
        'extended': extended,
        if (timestampMicros != null) 'timestampMicros': timestampMicros,
      };

  CanFrame copyWith({int? timestampMicros}) => CanFrame(
        bus: bus,
        id: id,
        data: _data,
        extended: extended,
        timestampMicros: timestampMicros ?? this.timestampMicros,
      );

  static Uint8List _validateAndCopyData(List<int> data) {
    if (data.length > 64) {
      throw ArgumentError.value(
          data.length, 'data', 'CAN-FD payload max is 64');
    }
    for (final byte in data) {
      if (byte < 0 || byte > 0xff) {
        throw ArgumentError.value(byte, 'data', 'Bytes must be in 0..255');
      }
    }
    return Uint8List.fromList(data);
  }

  static void _validateBus(String bus) {
    if (bus.isEmpty ||
        bus.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(bus)) {
      throw ArgumentError.value(bus, 'bus', 'Invalid CAN bus name');
    }
  }

  static void _validateIdentifier(int id, {required bool extended}) {
    final maximum = extended ? 0x1fffffff : 0x7ff;
    if (id < 0 || id > maximum) {
      throw ArgumentError.value(id, 'id', 'Outside CAN identifier range');
    }
  }

  @override
  String toString() =>
      'CanFrame(bus: $bus, id: 0x${id.toRadixString(16)}, length: $length)';
}

/// A filter applied by a provider before a frame reaches plugin code.
final class CanFilter {
  CanFilter({
    required this.bus,
    required this.id,
    required this.mask,
    this.extended,
  }) {
    if (bus.isEmpty ||
        bus.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(bus)) {
      throw ArgumentError.value(bus, 'bus', 'Invalid CAN bus name');
    }
    final maximum = extended == false ? 0x7ff : 0x1fffffff;
    if (id < 0 || id > maximum) {
      throw ArgumentError.value(id, 'id', 'Outside CAN identifier range');
    }
    if (mask < 0 || mask > maximum) {
      throw ArgumentError.value(mask, 'mask', 'Outside CAN mask range');
    }
  }

  final String bus;
  final int id;
  final int mask;
  final bool? extended;

  bool matches(CanFrame frame) =>
      frame.bus == bus &&
      (extended == null || extended == frame.extended) &&
      (frame.id & mask) == (id & mask);

  /// Whether every frame matched by [other] is also matched by this filter.
  bool covers(CanFilter other) =>
      bus == other.bus &&
      (extended == null || extended == other.extended) &&
      (other.mask & mask) == mask &&
      (other.id & mask) == (id & mask);

  @override
  String toString() => 'CanFilter(bus: $bus, id: 0x${id.toRadixString(16)}, '
      'mask: 0x${mask.toRadixString(16)}, extended: $extended)';
}
