import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../features/settings/settings_providers.dart';
import 'constants.dart';
import 'router.dart';
import 'run_alert_listener.dart';
import 'theme.dart';

class ModelsApp extends ConsumerWidget {
  const ModelsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      // fl_chart still imports the legacy package:flutter/material.dart, but
      // its line and bar charts don't read the legacy Theme, so no
      // MaterialUiCompatibilityBridge is needed. Add one in `builder` if a
      // future dependency renders legacy Material widgets.
      routerConfig: ref.watch(routerProvider),
      // Inside the ScaffoldMessenger, so alerts can show snack bars.
      builder: (context, child) => RunAlertListener(child: child ?? const SizedBox.shrink()),
    );
  }
}
