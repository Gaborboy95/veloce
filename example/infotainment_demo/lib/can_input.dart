import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

enum DemoCanInputState { disabled, starting, running, failed, stopped }

final class DemoCanInputStatus {
  const DemoCanInputStatus({
    required this.state,
    required this.transport,
    required this.message,
  });

  final DemoCanInputState state;
  final String transport;
  final String message;
}

/// Example-only bridge from a physical CAN transport into the filtered core
/// provider. The reusable Veloce packages remain transport-independent.
final class DemoCanInputController {
  DemoCanInputController._(this._transport, this._status);

  factory DemoCanInputController.memory() => DemoCanInputController._(
    null,
    const DemoCanInputStatus(
      state: DemoCanInputState.disabled,
      transport: 'Manual injection',
      message: 'No physical CAN input is configured.',
    ),
  );

  factory DemoCanInputController.fromEnvironment(
    Map<String, String> environment,
  ) {
    final mode = (environment['VELOCE_CAN_INPUT'] ?? 'auto').toLowerCase();
    final logicalBus = environment['VELOCE_CAN_BUS'] ?? 'comfort';
    final socketCanInterface =
        environment['VELOCE_SOCKETCAN_INTERFACE'] ?? 'can0';
    final lawicelPort = environment['VELOCE_LAWICEL_PORT'];

    final _CanInputTransport? transport = switch (mode) {
      'memory' => null,
      'socketcan' => _SocketCanTransport(
        interfaceName: socketCanInterface,
        logicalBus: logicalBus,
      ),
      'lawicel' when lawicelPort != null && lawicelPort.isNotEmpty =>
        _LawicelSerialTransport(
          portName: lawicelPort,
          logicalBus: logicalBus,
          serialBaudRate: _environmentInt(
            environment,
            'VELOCE_LAWICEL_SERIAL_BAUD',
            115200,
          ),
          canBitRate: _environmentInt(
            environment,
            'VELOCE_CAN_BITRATE',
            500000,
          ),
        ),
      'lawicel' => throw ArgumentError(
        'VELOCE_LAWICEL_PORT is required for LAWICEL input.',
      ),
      'auto' when Platform.isLinux => _SocketCanTransport(
        interfaceName: socketCanInterface,
        logicalBus: logicalBus,
      ),
      'auto'
          when Platform.isWindows &&
              lawicelPort != null &&
              lawicelPort.isNotEmpty =>
        _LawicelSerialTransport(
          portName: lawicelPort,
          logicalBus: logicalBus,
          serialBaudRate: _environmentInt(
            environment,
            'VELOCE_LAWICEL_SERIAL_BAUD',
            115200,
          ),
          canBitRate: _environmentInt(
            environment,
            'VELOCE_CAN_BITRATE',
            500000,
          ),
        ),
      'auto' => null,
      _ => throw ArgumentError.value(
        mode,
        'VELOCE_CAN_INPUT',
        'Expected auto, memory, socketcan, or lawicel.',
      ),
    };

    if (transport == null) return DemoCanInputController.memory();
    return DemoCanInputController._(
      transport,
      DemoCanInputStatus(
        state: DemoCanInputState.stopped,
        transport: transport.description,
        message: 'CAN input is not started.',
      ),
    );
  }

  final _CanInputTransport? _transport;
  final StreamController<DemoCanInputStatus> _statuses =
      StreamController<DemoCanInputStatus>.broadcast(sync: true);
  DemoCanInputStatus _status;
  StreamSubscription<CanFrame>? _frames;
  bool _closed = false;

  DemoCanInputStatus get currentStatus => _status;
  Stream<DemoCanInputStatus> get statuses => _statuses.stream;

  Future<void> start(InMemoryCanProvider provider) async {
    if (_closed) throw StateError('CAN input controller is closed.');
    final transport = _transport;
    if (transport == null) return;

    _setStatus(DemoCanInputState.starting, 'Opening CAN input.');
    _frames = transport.frames.listen(
      provider.inject,
      onError: (Object error, StackTrace stackTrace) {
        _setStatus(DemoCanInputState.failed, error.toString());
      },
    );
    try {
      await transport.start();
      _setStatus(DemoCanInputState.running, 'Receiving CAN frames.');
    } catch (error) {
      await _frames?.cancel();
      _frames = null;
      await transport.close();
      _setStatus(DemoCanInputState.failed, error.toString());
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _frames?.cancel();
    _frames = null;
    await _transport?.close();
    _setStatus(DemoCanInputState.stopped, 'CAN input stopped.');
    await _statuses.close();
  }

  void _setStatus(DemoCanInputState state, String message) {
    _status = DemoCanInputStatus(
      state: state,
      transport: _status.transport,
      message: message,
    );
    if (!_statuses.isClosed) _statuses.add(_status);
  }

  static int _environmentInt(
    Map<String, String> environment,
    String name,
    int defaultValue,
  ) {
    final raw = environment[name];
    if (raw == null) return defaultValue;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw ArgumentError.value(raw, name, 'Must be a positive integer.');
    }
    return value;
  }
}

abstract interface class _CanInputTransport {
  String get description;
  Stream<CanFrame> get frames;
  Future<void> start();
  Future<void> close();
}

final class _SocketCanTransport implements _CanInputTransport {
  _SocketCanTransport({required this.interfaceName, required this.logicalBus});

  final String interfaceName;
  final String logicalBus;
  final StreamController<CanFrame> _frames =
      StreamController<CanFrame>.broadcast(sync: true);
  _LinuxSocketBindings? _bindings;
  Pointer<Uint8>? _buffer;
  Timer? _poller;
  int _socket = -1;
  bool _closed = false;

  @override
  String get description => 'SocketCAN $interfaceName → $logicalBus';

  @override
  Stream<CanFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (!Platform.isLinux) {
      throw UnsupportedError('SocketCAN input is available only on Linux.');
    }
    if (_closed) throw StateError('SocketCAN input is closed.');
    final bindings = _LinuxSocketBindings.open();
    _bindings = bindings;
    final name = interfaceName.toNativeUtf8();
    try {
      final interfaceIndex = bindings.ifNameToIndex(name);
      if (interfaceIndex == 0) {
        throw FileSystemException(
          'SocketCAN interface does not exist',
          interfaceName,
        );
      }

      const socketFlags = _sockRaw | _sockNonBlock | _sockCloseOnExec;
      _socket = bindings.socket(_afCan, socketFlags, _canRaw);
      if (_socket < 0) {
        throw FileSystemException(
          'Could not create SocketCAN socket (errno ${bindings.errno})',
          interfaceName,
        );
      }

      final address = calloc<Uint8>(_sockaddrCanSize);
      try {
        address.cast<Uint16>().value = _afCan;
        (address + 4).cast<Uint32>().value = interfaceIndex;
        if (bindings.bind(_socket, address.cast(), _sockaddrCanSize) != 0) {
          throw FileSystemException(
            'Could not bind SocketCAN socket (errno ${bindings.errno})',
            interfaceName,
          );
        }
      } finally {
        calloc.free(address);
      }

      final enableFd = calloc<Int32>()..value = 1;
      try {
        // Best effort: classic CAN remains available on kernels without FD.
        bindings.setSockOpt(
          _socket,
          _solCanRaw,
          _canRawFdFrames,
          enableFd.cast(),
          sizeOf<Int32>(),
        );
      } finally {
        calloc.free(enableFd);
      }

      _buffer = calloc<Uint8>(_canFdFrameSize);
      _poller = Timer.periodic(
        const Duration(milliseconds: 4),
        (_) => _drainSocket(),
      );
    } catch (_) {
      await close();
      rethrow;
    } finally {
      calloc.free(name);
    }
  }

  void _drainSocket() {
    final bindings = _bindings;
    final buffer = _buffer;
    if (_socket < 0 || bindings == null || buffer == null) return;

    // Bound the work done during one UI-isolate turn.
    for (var received = 0; received < 128; received++) {
      final length = bindings.receive(
        _socket,
        buffer.cast(),
        _canFdFrameSize,
        0,
      );
      if (length <= 0) return;
      if (length != _canFrameSize && length != _canFdFrameSize) continue;

      final bytes = buffer.asTypedList(length);
      final data = ByteData.sublistView(bytes);
      final rawId = data.getUint32(0, Endian.host);
      if ((rawId & (_canRtrFlag | _canErrorFlag)) != 0) continue;
      final extended = (rawId & _canExtendedFlag) != 0;
      final id = rawId & (extended ? _canExtendedMask : _canStandardMask);
      final payloadLength = bytes[4];
      final maximumPayload = length == _canFdFrameSize ? 64 : 8;
      if (payloadLength > maximumPayload) continue;

      _frames.add(
        CanFrame(
          bus: logicalBus,
          id: id,
          data: Uint8List.fromList(bytes.sublist(8, 8 + payloadLength)),
          extended: extended,
          timestampMicros: DateTime.now().microsecondsSinceEpoch,
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poller?.cancel();
    _poller = null;
    final buffer = _buffer;
    _buffer = null;
    if (buffer != null) calloc.free(buffer);
    if (_socket >= 0) _bindings?.closeSocket(_socket);
    _socket = -1;
    await _frames.close();
  }
}

final class _LawicelSerialTransport implements _CanInputTransport {
  _LawicelSerialTransport({
    required this.portName,
    required this.logicalBus,
    required this.serialBaudRate,
    required this.canBitRate,
  });

  final String portName;
  final String logicalBus;
  final int serialBaudRate;
  final int canBitRate;
  final StreamController<CanFrame> _frames =
      StreamController<CanFrame>.broadcast(sync: true);
  final BytesBuilder _line = BytesBuilder(copy: false);
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSubscription;
  Completer<void>? _acknowledgement;
  bool _closed = false;

  @override
  String get description => 'LAWICEL $portName → $logicalBus';

  @override
  Stream<CanFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_closed) throw StateError('LAWICEL input is closed.');
    final bitRateCommand = _lawicelBitRateCommands[canBitRate];
    if (bitRateCommand == null) {
      throw ArgumentError.value(
        canBitRate,
        'VELOCE_CAN_BITRATE',
        'LAWICEL standard rates are ${_lawicelBitRateCommands.keys.join(', ')}.',
      );
    }

    final port = SerialPort(portName);
    _port = port;
    if (!port.openReadWrite()) {
      throw SerialPortError(
        'Could not open $portName: ${SerialPort.lastError}',
      );
    }
    final configuration = SerialPortConfig();
    try {
      configuration
        ..baudRate = serialBaudRate
        ..bits = 8
        ..parity = SerialPortParity.none
        ..stopBits = 1
        ..setFlowControl(SerialPortFlowControl.none);
      port.config = configuration;
    } finally {
      configuration.dispose();
    }

    _reader = SerialPortReader(port);
    _readerSubscription = _reader!.stream.listen(
      _onBytes,
      onError: (Object error, StackTrace stackTrace) {
        if (!_frames.isClosed) _frames.addError(error, stackTrace);
      },
    );

    // Closing first makes startup deterministic after a previous process.
    try {
      await _command('C');
    } catch (_) {
      // An already-closed adapter may answer with BELL; rate setup can proceed.
    }
    await _command(bitRateCommand);
    await _command('O');
  }

  void _onBytes(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte == _bell) {
        _line.clear();
        final acknowledgement = _acknowledgement;
        _acknowledgement = null;
        acknowledgement?.completeError(
          StateError('LAWICEL adapter rejected the command.'),
        );
        continue;
      }
      if (byte != _carriageReturn) {
        if (_line.length < 128) _line.addByte(byte);
        continue;
      }

      final lineBytes = _line.takeBytes();
      if (lineBytes.isEmpty) {
        final acknowledgement = _acknowledgement;
        _acknowledgement = null;
        acknowledgement?.complete();
        continue;
      }
      final line = ascii.decode(lineBytes, allowInvalid: true);
      final frame = LawicelCodec.tryParse(line, bus: logicalBus);
      if (frame != null && !_frames.isClosed) _frames.add(frame);
    }
  }

  Future<void> _command(String command) async {
    if (_acknowledgement != null) {
      throw StateError('A LAWICEL command is already pending.');
    }
    final port = _port;
    if (port == null || !port.isOpen) {
      throw StateError('LAWICEL serial port is not open.');
    }
    final acknowledgement = Completer<void>();
    _acknowledgement = acknowledgement;
    final bytes = Uint8List.fromList(ascii.encode('$command\r'));
    final written = port.write(bytes, timeout: 1000);
    if (written != bytes.length) {
      _acknowledgement = null;
      throw StateError('Short write while sending LAWICEL command $command.');
    }
    try {
      await acknowledgement.future.timeout(const Duration(seconds: 2));
    } finally {
      if (identical(_acknowledgement, acknowledgement)) {
        _acknowledgement = null;
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final openPort = _port;
    if (openPort != null && openPort.isOpen && _acknowledgement == null) {
      try {
        await _command('C');
      } catch (_) {
        // Physical disconnects must not prevent local resource cleanup.
      }
    }
    final pending = _acknowledgement;
    _acknowledgement = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('LAWICEL input closed.'));
    }
    await _readerSubscription?.cancel();
    _readerSubscription = null;
    _reader?.close();
    _reader = null;
    final port = _port;
    _port = null;
    if (port != null) {
      if (port.isOpen) port.close();
      port.dispose();
    }
    await _frames.close();
  }
}

/// Parser for LAWICEL/SLCAN `t` and `T` data-frame records.
abstract final class LawicelCodec {
  static CanFrame? tryParse(String record, {required String bus}) {
    if (record.isEmpty) return null;
    final extended = switch (record.codeUnitAt(0)) {
      0x74 => false, // t
      0x54 => true, // T
      _ => null,
    };
    if (extended == null) return null;

    final idDigits = extended ? 8 : 3;
    final headerLength = 1 + idDigits + 1;
    if (record.length < headerLength) return null;
    final id = int.tryParse(record.substring(1, 1 + idDigits), radix: 16);
    final dataLength = int.tryParse(
      record.substring(1 + idDigits, headerLength),
      radix: 16,
    );
    if (id == null || dataLength == null || dataLength > 8) return null;
    final payloadEnd = headerLength + dataLength * 2;
    if (record.length != payloadEnd && record.length != payloadEnd + 4) {
      return null;
    }

    final payload = <int>[];
    for (var offset = headerLength; offset < payloadEnd; offset += 2) {
      final byte = int.tryParse(
        record.substring(offset, offset + 2),
        radix: 16,
      );
      if (byte == null) return null;
      payload.add(byte);
    }
    final timestamp = record.length == payloadEnd + 4
        ? int.tryParse(record.substring(payloadEnd), radix: 16)
        : null;
    if (record.length == payloadEnd + 4 && timestamp == null) return null;

    try {
      return CanFrame(
        bus: bus,
        id: id,
        data: payload,
        extended: extended,
        timestampMicros: timestamp == null ? null : timestamp * 1000,
      );
    } on ArgumentError {
      return null;
    }
  }
}

final class _LinuxSocketBindings {
  _LinuxSocketBindings(this.library)
    : socket = library.lookupFunction<_SocketNative, _SocketDart>('socket'),
      bind = library.lookupFunction<_BindNative, _BindDart>('bind'),
      receive = library.lookupFunction<_ReceiveNative, _ReceiveDart>('recv'),
      setSockOpt = library.lookupFunction<_SetSockOptNative, _SetSockOptDart>(
        'setsockopt',
      ),
      closeSocket = library.lookupFunction<_CloseNative, _CloseDart>('close'),
      ifNameToIndex = library
          .lookupFunction<_IfNameToIndexNative, _IfNameToIndexDart>(
            'if_nametoindex',
          ),
      _errnoLocation = library
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
            '__errno_location',
          );

  factory _LinuxSocketBindings.open() {
    for (final name in const ['libc.so.6', 'libc.so']) {
      try {
        return _LinuxSocketBindings(DynamicLibrary.open(name));
      } on ArgumentError {
        // Try the next conventional libc name.
      }
    }
    throw UnsupportedError('Could not load libc for SocketCAN.');
  }

  final DynamicLibrary library;
  final _SocketDart socket;
  final _BindDart bind;
  final _ReceiveDart receive;
  final _SetSockOptDart setSockOpt;
  final _CloseDart closeSocket;
  final _IfNameToIndexDart ifNameToIndex;
  final _ErrnoLocationDart _errnoLocation;

  int get errno => _errnoLocation().value;
}

typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _BindNative = Int32 Function(Int32, Pointer<Void>, Uint32);
typedef _BindDart = int Function(int, Pointer<Void>, int);
typedef _ReceiveNative = IntPtr Function(Int32, Pointer<Void>, UintPtr, Int32);
typedef _ReceiveDart = int Function(int, Pointer<Void>, int, int);
typedef _SetSockOptNative = Int32 Function(
  Int32,
  Int32,
  Int32,
  Pointer<Void>,
  Uint32,
);
typedef _SetSockOptDart = int Function(int, int, int, Pointer<Void>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _IfNameToIndexNative = Uint32 Function(Pointer<Utf8>);
typedef _IfNameToIndexDart = int Function(Pointer<Utf8>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

const _afCan = 29;
const _sockRaw = 3;
const _sockNonBlock = 0x800;
const _sockCloseOnExec = 0x80000;
const _canRaw = 1;
const _solCanRaw = 101;
const _canRawFdFrames = 5;
const _sockaddrCanSize = 16;
const _canFrameSize = 16;
const _canFdFrameSize = 72;
const _canExtendedFlag = 0x80000000;
const _canRtrFlag = 0x40000000;
const _canErrorFlag = 0x20000000;
const _canStandardMask = 0x7ff;
const _canExtendedMask = 0x1fffffff;
const _carriageReturn = 13;
const _bell = 7;

const _lawicelBitRateCommands = <int, String>{
  10000: 'S0',
  20000: 'S1',
  50000: 'S2',
  100000: 'S3',
  125000: 'S4',
  250000: 'S5',
  500000: 'S6',
  800000: 'S7',
  1000000: 'S8',
};
