import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  test('in-memory provider filters before invoking plugin handlers', () async {
    final provider = InMemoryCanProvider();
    final received = <CanFrame>[];
    await provider.subscribe(
      ownerId: 'dev.example.decoder',
      filter: CanFilter(bus: 'comfort', id: 0x280, mask: 0x7ff),
      onFrame: received.add,
    );

    final miss = provider.inject(
      CanFrame(bus: 'comfort', id: 0x281, data: [1, 2]),
    );
    final hit = provider.inject(
      CanFrame(bus: 'comfort', id: 0x280, data: [0x12, 0x34]),
    );
    await provider.flush();

    expect(miss.matchedSubscriptions, 0);
    expect(hit.matchedSubscriptions, 1);
    expect(received.single.id, 0x280);
    expect(received.single.data, [0x12, 0x34]);
    await provider.close();
  });

  test('CAN writes are denied by default', () async {
    final provider = InMemoryCanProvider();
    await expectLater(
      provider.send(
        ownerId: 'dev.example.decoder',
        frame: CanFrame(bus: 'comfort', id: 0x500, data: [1]),
      ),
      throwsA(isA<CanWriteDisabledException>()),
    );
    await provider.close();
  });

  test('scoped policy restricts filters, IDs and write rate', () async {
    final policy = ConfigurableCanAuthorizationPolicy()
      ..setGrant(
        'dev.example.decoder',
        CanAccessGrant(
          readFilters: [
            CanFilter(bus: 'comfort', id: 0x280, mask: 0x7f0),
          ],
          writeFilters: [
            CanFilter(bus: 'comfort', id: 0x500, mask: 0x7ff),
          ],
          maxSendRatePerSecond: 1,
        ),
      );
    final provider = InMemoryCanProvider(
      writesEnabled: true,
      authorizationPolicy: policy,
    );
    await provider.subscribe(
      ownerId: 'dev.example.decoder',
      filter: CanFilter(bus: 'comfort', id: 0x280, mask: 0x7ff),
      onFrame: (_) {},
    );
    final frame = CanFrame(bus: 'comfort', id: 0x500, data: [1]);
    await provider.send(ownerId: 'dev.example.decoder', frame: frame);
    await expectLater(
      provider.send(ownerId: 'dev.example.decoder', frame: frame),
      throwsA(isA<PluginPermissionException>()),
    );
    expect(provider.sentHistory, hasLength(1));
    await provider.close();
  });
}
