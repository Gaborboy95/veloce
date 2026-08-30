import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infotainment_demo/can_input.dart';
import 'package:infotainment_demo/demo_runtime.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  test('demo environment loads dotenv syntax with process overrides', () async {
    final directory = await Directory.systemTemp.createTemp('veloce-env-test-');
    final file = File.fromUri(directory.uri.resolve('test.env'));
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsString(r'''
# Comment
VELOCE_CAN_INPUT=memory
DOUBLE="line\nvalue"
SINGLE='literal value'
export INLINE=value # trailing comment
OVERRIDE=file
''');

    final environment = await DemoEnvironment.load(
      ['--env-file=${file.path}'],
      processEnvironment: const {'OVERRIDE': 'process'},
    );

    expect(environment.sourceFile?.absolute.path, file.absolute.path);
    expect(environment.values['VELOCE_CAN_INPUT'], 'memory');
    expect(environment.values['DOUBLE'], 'line\nvalue');
    expect(environment.values['SINGLE'], 'literal value');
    expect(environment.values['INLINE'], 'value');
    expect(environment.values['OVERRIDE'], 'process');
  });

  test('explicit missing environment file fails clearly', () async {
    final missing = File.fromUri(
      Directory.systemTemp.uri.resolve('veloce-missing-env-file'),
    );

    await expectLater(
      DemoEnvironment.load([
        '--env-file',
        missing.path,
      ], processEnvironment: const {}),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('LAWICEL parser decodes standard data frames', () {
    final frame = LawicelCodec.tryParse('t28020BB8', bus: 'comfort');

    expect(frame, isNotNull);
    expect(frame!.bus, 'comfort');
    expect(frame.id, 0x280);
    expect(frame.extended, isFalse);
    expect(frame.data, [0x0b, 0xb8]);
  });

  test('LAWICEL parser decodes extended frames and adapter timestamps', () {
    final frame = LawicelCodec.tryParse(
      'T000001AB301020300FF',
      bus: 'diagnostic',
    );

    expect(frame, isNotNull);
    expect(frame!.id, 0x1ab);
    expect(frame.extended, isTrue);
    expect(frame.data, [1, 2, 3]);
    expect(frame.timestampMicros, 255000);
  });

  test('LAWICEL codec handles RTR and rejects malformed records', () {
    final remote = LawicelCodec.tryParse('r2804', bus: 'comfort');
    expect(remote, isNotNull);
    expect(remote!.kind, CanFrameKind.remote);
    expect(remote.remoteLength, 4);
    expect(LawicelCodec.encode(remote), 'r2804');
    expect(
      LawicelCodec.encode(
        CanFrame(bus: 'comfort', id: 0x280, data: const [0x0b, 0xb8]),
      ),
      't28020BB8',
    );
    expect(LawicelCodec.tryParse('t2802AA', bus: 'comfort'), isNull);
    expect(LawicelCodec.tryParse('t2809', bus: 'comfort'), isNull);
    expect(LawicelCodec.tryParse('TFFFFFFFF0', bus: 'comfort'), isNull);
  });
}
