import 'package:flutter/material.dart';

import 'app.dart';
import 'core/state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppController.create();
  runApp(SiStudioApp(controller: controller));
}
