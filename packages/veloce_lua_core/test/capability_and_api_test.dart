import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:test/test.dart';

PluginManifest manifestWith(Iterable<Capability> capabilities) =>
    PluginManifest(
      id: 'dev.example.test',
      name: 'Test',
      version: SemanticVersion.parse('1.0.0'),
      apiVersion: '1',
      entrypoint: 'main.lua',
      permissions: capabilities,
    );

void main() {
  test(
    'requested capabilities are checked and CAN writes default to denied',
    () {
      final capabilities = CapabilityManager();
      capabilities.registerPlugin(
        manifestWith([
          BuiltInCapabilities.logging,
          BuiltInCapabilities.canWrite,
        ]),
      );

      expect(
        capabilities.isGranted('dev.example.test', BuiltInCapabilities.logging),
        isTrue,
      );
      expect(
        () => capabilities.require(
          'dev.example.test',
          BuiltInCapabilities.canWrite,
        ),
        throwsA(isA<PluginPermissionException>()),
      );
    },
  );

  test('API registry checks capability and preserves callback arguments', () {
    final capabilities = CapabilityManager();
    capabilities.registerPlugin(manifestWith([BuiltInCapabilities.events]));
    final registry = PluginApiRegistry(capabilityManager: capabilities);
    registry.registerNamespace(
      PluginApiNamespace(
        name: 'events',
        methods: {
          'subscribe': PluginApiMethod(
            capability: BuiltInCapabilities.events,
            handler: (call) {
              call.requireArgumentCount(2);
              final topic = call.dataAs<String>(0);
              final callback = call.callback(1);
              return {'topic': topic, 'callback': callback.callbackId};
            },
          ),
        },
      ),
    );
    const callback = PluginCallbackRef(
      pluginId: 'dev.example.test',
      generation: 'g1',
      callbackId: 7,
    );
    final result = registry.invoke(
      PluginApiCall(
        pluginId: 'dev.example.test',
        generation: 'g1',
        namespace: 'events',
        method: 'subscribe',
        arguments: const [
          PluginApiDataArgument('vehicle.ignition'),
          PluginApiCallbackArgument(callback),
        ],
      ),
    );

    expect(result, {'topic': 'vehicle.ignition', 'callback': 7});
  });

  test('API registry rejects callbacks from an old generation', () {
    final capabilities = CapabilityManager();
    capabilities.registerPlugin(manifestWith([BuiltInCapabilities.events]));
    final registry = PluginApiRegistry(capabilityManager: capabilities)
      ..registerNamespace(
        PluginApiNamespace(
          name: 'events',
          methods: {
            'subscribe': PluginApiMethod(
              capability: BuiltInCapabilities.events,
              handler: (_) => null,
            ),
          },
        ),
      );

    expect(
      () => registry.invoke(
        PluginApiCall(
          pluginId: 'dev.example.test',
          generation: 'new',
          namespace: 'events',
          method: 'subscribe',
          arguments: const [
            PluginApiCallbackArgument(
              PluginCallbackRef(
                pluginId: 'dev.example.test',
                generation: 'old',
                callbackId: 1,
              ),
            ),
          ],
        ),
      ),
      throwsA(isA<StalePluginCallbackException>()),
    );
  });
}
