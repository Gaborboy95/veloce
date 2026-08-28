import 'package:flutter/material.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../can_input.dart';
import '../demo_runtime.dart';

final class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.runtime});

  final DemoRuntime runtime;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  String _injectionStatus = 'No demo frame injected yet.';

  @override
  Widget build(BuildContext context) {
    final manager = widget.runtime.manager;
    final rpm = manager.vehicleDataBus.valueFor('engine.rpm')?.value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Home', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _MetricCard(
              label: 'Runtime plugins',
              value: manager.currentPlugins
                  .where((item) => item.state == PluginState.running)
                  .length
                  .toString(),
              icon: Icons.extension,
            ),
            _MetricCard(
              label: 'Engine speed',
              value: rpm == null ? '— RPM' : '$rpm RPM',
              icon: Icons.speed,
            ),
            _MetricCard(
              label: 'Dynamic tabs',
              value: manager.uiRegistry.currentTabs.length.toString(),
              icon: Icons.dashboard,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CAN → vehicle data → Lua dashboard',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Inject comfort-bus frame 0x280. The vehicle-specific Lua '
                  'decoder publishes engine.rpm; the dashboard plugin consumes '
                  'that abstract value without accessing CAN.',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _injectFrame,
                  icon: const Icon(Icons.bolt),
                  label: const Text('Inject 3000 RPM frame'),
                ),
                const SizedBox(height: 12),
                Text(_injectionStatus),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        StreamBuilder<DemoCanInputStatus>(
          stream: widget.runtime.canInput.statuses,
          initialData: widget.runtime.canInput.currentStatus,
          builder: (context, snapshot) {
            final status = snapshot.data!;
            return Card(
              child: ListTile(
                leading: Icon(
                  status.state == DemoCanInputState.running
                      ? Icons.cable
                      : status.state == DemoCanInputState.failed
                      ? Icons.error_outline
                      : Icons.usb_off,
                ),
                title: Text('CAN input: ${status.transport}'),
                subtitle: Text(status.message),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Watched plugin directory'),
            subtitle: SelectableText(widget.runtime.pluginDirectory.path),
          ),
        ),
      ],
    );
  }

  Future<void> _injectFrame() async {
    final result = widget.runtime.canProvider.inject(
      CanFrame(bus: 'comfort', id: 0x280, data: const [0x0b, 0xb8]),
    );
    await widget.runtime.canProvider.flush();
    await widget.runtime.manager.vehicleDataBus.flush();
    if (!mounted) return;
    setState(() {
      _injectionStatus = result.matchedSubscriptions == 0
          ? 'No decoder is subscribed. Enable dev.example.can_decoder.'
          : 'Delivered through ${result.matchedSubscriptions} filtered CAN '
                'subscription(s).';
    });
  }
}

final class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 230,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 32),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, overflow: TextOverflow.ellipsis),
                  Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
