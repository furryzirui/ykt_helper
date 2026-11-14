import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'services/app_logs.dart';
import 'services/app_autostart.dart';
import 'ui/app.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  FlutterError.onError = (details) {
    controller.logs.add(AppLogEvent.failure, success: false);
    FlutterError.presentError(details);
  };
  final foreground = ValueNotifier<bool>(
    !arguments.contains('--background-auto-start'),
  );
  AppAutostart.setForegroundListener(() => foreground.value = true);
  runApp(
    ValueListenableBuilder<bool>(
      valueListenable: foreground,
      builder: (context, visible, _) =>
          RainApp(controller: controller, startupChecks: visible),
    ),
  );
  controller.initialize();
}
