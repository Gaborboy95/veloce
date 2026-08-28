import 'package:flutter_test/flutter_test.dart';
import 'package:infotainment_demo/can_input.dart';

void main() {
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

  test('LAWICEL parser rejects RTR, malformed, and oversized records', () {
    expect(LawicelCodec.tryParse('r2800', bus: 'comfort'), isNull);
    expect(LawicelCodec.tryParse('t2802AA', bus: 'comfort'), isNull);
    expect(LawicelCodec.tryParse('t2809', bus: 'comfort'), isNull);
    expect(LawicelCodec.tryParse('TFFFFFFFF0', bus: 'comfort'), isNull);
  });
}
