import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  const codec = StructuredValueCodec();

  test('normalizes and freezes supported structured values', () {
    final source = <String, Object?>{
      'nil': null,
      'bool': true,
      'int': 2,
      'double': 2.5,
      'list': <Object?>['x', 1],
    };
    final result = codec.normalize(source) as Map<String, Object?>;
    source['int'] = 99;

    expect(result['int'], 2);
    expect(() => result['new'] = 1, throwsUnsupportedError);
  });

  test('rejects arbitrary objects, non-string keys, cycles and NaN', () {
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    for (final value in [
      DateTime.now(),
      <Object?, Object?>{1: 'bad'},
      cyclic,
      double.nan,
    ]) {
      expect(() => codec.normalize(value), throwsA(isA<PluginApiException>()));
    }
  });
}
