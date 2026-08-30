import 'dart:typed_data';

enum CanFrameKind {
  data,
  remote,
  error;

  String get wireName => name;
}

/// A transport-level CAN/CAN-FD frame.
final class CanFrame {
  CanFrame({
    required this.bus,
    required this.id,
    required List<int> data,
    this.extended = false,
    this.timestampMicros,
  }) : kind = CanFrameKind.data,
       remoteLength = null,
       errorFlags = null,
       _data = _validateAndCopyData(data) {
    _validateBus(bus);
    _validateIdentifier(id, extended: extended);
    _validateTimestamp(timestampMicros);
  }

  /// A remote-transmission-request frame.
  CanFrame.remote({
    required this.bus,
    required this.id,
    this.remoteLength = 0,
    this.extended = false,
    this.timestampMicros,
  }) : kind = CanFrameKind.remote,
       errorFlags = null,
       _data = Uint8List(0) {
    _validateBus(bus);
    _validateIdentifier(id, extended: extended);
    if (remoteLength! < 0 || remoteLength! > 8) {
      throw ArgumentError.value(
        remoteLength,
        'remoteLength',
        'Classic CAN RTR length must be in 0..8',
      );
    }
    _validateTimestamp(timestampMicros);
  }

  /// A Linux-compatible controller error frame.
  ///
  /// [errorFlags] uses the SocketCAN CAN_ERR_* bit layout. The optional data
  /// bytes retain controller-specific error details without interpreting them
  /// in the reusable runtime.
  CanFrame.error({
    required this.bus,
    required this.errorFlags,
    List<int> data = const [],
    this.timestampMicros,
  }) : kind = CanFrameKind.error,
       id = 0,
       extended = false,
       remoteLength = null,
       _data = _validateAndCopyErrorData(data) {
    _validateBus(bus);
    final flags = errorFlags!;
    if (flags < 0 || flags > 0x1fffffff) {
      throw ArgumentError.value(
        flags,
        'errorFlags',
        'Outside SocketCAN error-class range',
      );
    }
    _validateTimestamp(timestampMicros);
  }

  final String bus;
  final int id;
  final Uint8List _data;
  final bool extended;
  final int? timestampMicros;
  final CanFrameKind kind;
  final int? remoteLength;
  final int? errorFlags;

  bool get isData => kind == CanFrameKind.data;
  bool get isRemote => kind == CanFrameKind.remote;
  bool get isError => kind == CanFrameKind.error;

  /// A defensive copy; callers cannot mutate a frame after validation.
  Uint8List get data => Uint8List.fromList(_data);

  int get length => _data.length;

  Map<String, Object?> toStructuredValue() => {
    'bus': bus,
    'type': kind.wireName,
    'id': id,
    'data': List<int>.unmodifiable(_data),
    'extended': extended,
    if (remoteLength != null) 'remoteLength': remoteLength,
    if (errorFlags != null) 'errorFlags': errorFlags,
    if (timestampMicros != null) 'timestampMicros': timestampMicros,
  };

  CanFrame copyWith({int? timestampMicros}) => switch (kind) {
    CanFrameKind.data => CanFrame(
      bus: bus,
      id: id,
      data: _data,
      extended: extended,
      timestampMicros: timestampMicros ?? this.timestampMicros,
    ),
    CanFrameKind.remote => CanFrame.remote(
      bus: bus,
      id: id,
      remoteLength: remoteLength!,
      extended: extended,
      timestampMicros: timestampMicros ?? this.timestampMicros,
    ),
    CanFrameKind.error => CanFrame.error(
      bus: bus,
      errorFlags: errorFlags!,
      data: _data,
      timestampMicros: timestampMicros ?? this.timestampMicros,
    ),
  };

  static Uint8List _validateAndCopyData(List<int> data) {
    if (data.length > 64) {
      throw ArgumentError.value(
        data.length,
        'data',
        'CAN-FD payload max is 64',
      );
    }
    for (final byte in data) {
      if (byte < 0 || byte > 0xff) {
        throw ArgumentError.value(byte, 'data', 'Bytes must be in 0..255');
      }
    }
    return Uint8List.fromList(data);
  }

  static Uint8List _validateAndCopyErrorData(List<int> data) {
    if (data.length > 8) {
      throw ArgumentError.value(
        data.length,
        'data',
        'SocketCAN error payload max is 8',
      );
    }
    return _validateAndCopyData(data);
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

  static void _validateTimestamp(int? timestampMicros) {
    if (timestampMicros case final value? when value < 0) {
      throw ArgumentError.value(
        timestampMicros,
        'timestampMicros',
        'Must not be negative',
      );
    }
  }

  @override
  String toString() => switch (kind) {
    CanFrameKind.data =>
      'CanFrame(bus: $bus, id: 0x${id.toRadixString(16)}, length: $length)',
    CanFrameKind.remote =>
      'CanRemoteFrame(bus: $bus, id: 0x${id.toRadixString(16)}, requestedLength: $remoteLength)',
    CanFrameKind.error =>
      'CanErrorFrame(bus: $bus, flags: 0x${errorFlags!.toRadixString(16)})',
  };
}

/// A filter applied by a provider before a frame reaches plugin code.
final class CanFilter {
  CanFilter({
    required this.bus,
    int? id,
    Iterable<int>? ids,
    int? mask,
    this.extended,
    this.includeRemote = false,
    this.includeErrors = false,
  }) : ids = List.unmodifiable(_normalizeIdentifiers(id, ids)),
       mask = mask ?? (extended == false ? 0x7ff : 0x1fffffff) {
    if (bus.isEmpty ||
        bus.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(bus)) {
      throw ArgumentError.value(bus, 'bus', 'Invalid CAN bus name');
    }
    final maximum = extended == false ? 0x7ff : 0x1fffffff;
    for (final identifier in this.ids) {
      if (identifier < 0 || identifier > maximum) {
        throw ArgumentError.value(
          identifier,
          'ids',
          'Outside CAN identifier range',
        );
      }
    }
    if (this.mask < 0 || this.mask > maximum) {
      throw ArgumentError.value(this.mask, 'mask', 'Outside CAN mask range');
    }
  }

  final String bus;
  final List<int> ids;
  final int mask;
  final bool? extended;
  final bool includeRemote;
  final bool includeErrors;

  /// The identifier for a single-ID filter, otherwise `null`.
  ///
  /// Prefer [ids] when handling filters generically. An empty [ids] list is a
  /// wildcard that accepts every identifier on [bus].
  int? get id => ids.length == 1 ? ids.single : null;

  bool get matchesAllIds => ids.isEmpty;

  bool matches(CanFrame frame) {
    if (frame.bus != bus) return false;
    if (frame.isError) return includeErrors;
    if (frame.isRemote && !includeRemote) return false;
    return (extended == null || extended == frame.extended) &&
        (matchesAllIds ||
            ids.any((identifier) => (frame.id & mask) == (identifier & mask)));
  }

  /// Whether every frame matched by [other] is also matched by this filter.
  bool covers(CanFilter other) =>
      bus == other.bus &&
      (!other.includeRemote || includeRemote) &&
      (!other.includeErrors || includeErrors) &&
      (extended == null || extended == other.extended) &&
      (matchesAllIds ||
          (!other.matchesAllIds &&
              other.ids.every(
                (otherId) => ids.any(
                  (id) =>
                      (other.mask & mask) == mask &&
                      (otherId & mask) == (id & mask),
                ),
              )));

  static Iterable<int> _normalizeIdentifiers(int? id, Iterable<int>? ids) {
    if (id != null && ids != null) {
      throw ArgumentError('Specify either id or ids, not both.');
    }
    if (id != null) return [id];
    return ids == null ? const [] : <int>{...ids};
  }

  @override
  String toString() {
    final idDescription = matchesAllIds
        ? '*'
        : ids.map((id) => '0x${id.toRadixString(16)}').join(', ');
    return 'CanFilter(bus: $bus, ids: [$idDescription], '
        'mask: 0x${mask.toRadixString(16)}, extended: $extended, '
        'includeRemote: $includeRemote, includeErrors: $includeErrors)';
  }
}

/// Manifest/host grant applied in addition to the coarse can.read/can.write
/// capabilities.
final class CanAccessGrant {
  CanAccessGrant({
    Iterable<CanFilter> readFilters = const [],
    Iterable<CanFilter> writeFilters = const [],
    this.maxSendRatePerSecond = 0,
  }) : readFilters = List.unmodifiable(readFilters),
       writeFilters = List.unmodifiable(writeFilters) {
    if (maxSendRatePerSecond < 0) {
      throw ArgumentError.value(
        maxSendRatePerSecond,
        'maxSendRatePerSecond',
        'Must not be negative',
      );
    }
    if (writeFilters.any((filter) => filter.includeErrors)) {
      throw ArgumentError('CAN error frames cannot be granted for writes.');
    }
  }

  final List<CanFilter> readFilters;
  final List<CanFilter> writeFilters;
  final int maxSendRatePerSecond;

  bool get permitsReads => readFilters.isNotEmpty;
  bool get permitsWrites => writeFilters.isNotEmpty && maxSendRatePerSecond > 0;
}
