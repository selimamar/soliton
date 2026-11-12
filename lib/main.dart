import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app.dart';

void main() {
  // Clean web URLs (/runs/x instead of /#/runs/x). No effect on iOS/Android.
  usePathUrlStrategy();
  // ProviderScope holds the state of every Riverpod provider in the app.
  runApp(const ProviderScope(child: ModelsApp()));
}
