import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'services/app_logs.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  FlutterError.onError = (details) {
    controller.logs.add(AppLogEvent.failure, success: false);
    FlutterError.presentError(details);
  };
  runApp(RainApp(controller: controller));
  controller.initialize();
}
