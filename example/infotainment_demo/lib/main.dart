import 'package:flutter/material.dart';

import 'demo_runtime.dart';
import 'infotainment_app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final runtime = await DemoRuntime.create(arguments);
    runApp(InfotainmentDemo(runtime: runtime));
  } catch (error, stackTrace) {
    runApp(DemoStartupFailure(error: error, stackTrace: stackTrace));
  }
}
