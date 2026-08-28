import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:ivi_lua_flutter/ivi_lua_flutter.dart';

const _pluginId = 'dev.example.test';
const _callback = PluginCallbackRef(
  pluginId: _pluginId,
  generation: 'generation-1',
  callbackId: 7,
);

void main() {
  testWidgets('renders text and nested layouts', (tester) async {
    final builder = PluginWidgetBuilder(callbackInvoker: (_, _) async {});
    final root = PluginColumnNode([
      const PluginTextNode('Plugin title', bold: true),
      PluginRowNode(const [
        PluginTextNode('Left'),
        PluginSpacerNode(),
        PluginTextNode('Right'),
      ], spacing: 8),
    ], spacing: 12);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: builder.build(root, pluginId: _pluginId)),
      ),
    );

    expect(find.text('Plugin title'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);
    expect(find.byType(Column), findsOneWidget);
    expect(find.byType(Row), findsOneWidget);
    expect(find.byType(Spacer), findsOneWidget);
  });

  testWidgets('button invokes the referenced plugin callback', (tester) async {
    PluginCallbackRef? receivedCallback;
    List<Object?>? receivedArguments;
    final builder = PluginWidgetBuilder(
      callbackInvoker: (callback, arguments) async {
        receivedCallback = callback;
        receivedArguments = arguments;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: builder.build(
            const PluginButtonNode(text: 'Run', onPressed: _callback),
            pluginId: _pluginId,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Run'));
    await tester.pump();

    expect(receivedCallback, _callback);
    expect(receivedArguments, isEmpty);
  });

  testWidgets('contains stale callback failures', (tester) async {
    Object? reportedError;
    final builder = PluginWidgetBuilder(
      callbackInvoker: (_, _) async {
        throw const StalePluginCallbackException(
          'The runtime generation was unloaded.',
          pluginId: _pluginId,
        );
      },
      onError: (error, _) => reportedError = error,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: builder.build(
            const PluginButtonNode(text: 'Old action', onPressed: _callback),
            pluginId: _pluginId,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Old action'));
    await tester.pump();

    expect(reportedError, isA<StalePluginCallbackException>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects callback references owned by another plugin', (
    tester,
  ) async {
    Object? reportedError;
    var invocationCount = 0;
    final builder = PluginWidgetBuilder(
      callbackInvoker: (_, _) async => invocationCount++,
      onError: (error, _) => reportedError = error,
    );
    const foreignCallback = PluginCallbackRef(
      pluginId: 'dev.example.other',
      generation: 'generation-1',
      callbackId: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: builder.build(
            const PluginButtonNode(
              text: 'Foreign action',
              onPressed: foreignCallback,
            ),
            pluginId: _pluginId,
          ),
        ),
      ),
    );

    expect(find.text('Plugin UI unavailable'), findsOneWidget);
    expect(find.text('Foreign action'), findsNothing);
    expect(reportedError, isA<PluginApiException>());
    expect(invocationCount, 0);
    expect(tester.takeException(), isNull);
  });
}
