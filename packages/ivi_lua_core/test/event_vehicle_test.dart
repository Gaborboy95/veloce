import 'dart:async';

import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  test('event queues are bounded and owner cleanup removes subscriptions',
      () async {
    final gate = Completer<void>();
    final values = <int>[];
    final bus = PluginEventBus(maxPendingPerSubscription: 2);
    bus.subscribe(
      ownerId: 'dev.example.slow',
      topic: 'test.value',
      handler: (event) async {
        values.add(event.data! as int);
        if (values.length == 1) await gate.future;
      },
    );

    bus.publish('test.value', 0);
    bus.publish('test.value', 1);
    bus.publish('test.value', 2);
    final fourth = bus.publish('test.value', 3);
    final fifth = bus.publish('test.value', 4);
    expect(fourth.droppedDeliveries + fifth.droppedDeliveries, 2);
    gate.complete();
    await bus.flush();
    expect(values, [0, 3, 4]);

    await bus.removeOwner('dev.example.slow');
    expect(bus.subscriptionCountFor('dev.example.slow'), 0);
    expect(bus.publish('test.value', 5).matchedSubscriptions, 0);
    await bus.close();
  });

  test('vehicle bus coalesces rapid values and retains latest', () async {
    final gate = Completer<void>();
    final values = <int>[];
    final bus = VehicleDataBus();
    bus.subscribe(
      ownerId: 'dev.example.dashboard',
      key: 'engine.rpm',
      handler: (point) async {
        values.add(point.value! as int);
        if (values.length == 1) await gate.future;
      },
    );
    bus.publish('engine.rpm', 1000, sourcePluginId: 'dev.example.decoder');
    bus.publish('engine.rpm', 2000, sourcePluginId: 'dev.example.decoder');
    final result =
        bus.publish('engine.rpm', 3000, sourcePluginId: 'dev.example.decoder');
    expect(result.coalescedUpdates, 1);
    gate.complete();
    await bus.flush();

    expect(values, [1000, 3000]);
    expect(bus.valueFor('engine.rpm')?.value, 3000);
    await bus.removeOwner('dev.example.dashboard');
    await bus.close();
  });

  test('reentrant event publication remains sequential', () async {
    final bus = PluginEventBus();
    var activeHandlers = 0;
    var maximumActiveHandlers = 0;
    final delivered = <int>[];
    bus.subscribe(
      ownerId: 'dev.example.reentrant',
      topic: 'test.reentrant',
      handler: (event) {
        activeHandlers++;
        if (activeHandlers > maximumActiveHandlers) {
          maximumActiveHandlers = activeHandlers;
        }
        final value = event.data! as int;
        delivered.add(value);
        if (value == 1) bus.publish('test.reentrant', 2);
        activeHandlers--;
      },
    );

    bus.publish('test.reentrant', 1);
    await bus.flush();

    expect(delivered, [1, 2]);
    expect(maximumActiveHandlers, 1);
    await bus.close();
  });
}
