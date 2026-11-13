import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/services/settings_store.dart';

// App settings, saved on the device (see `Setting`). The server login is
// `connectionProvider` in data/providers.dart; chart options are in
// shared/chart_settings.dart.

final themeModeProvider = NotifierProvider<Setting<ThemeMode>, ThemeMode>(
  () => Setting.choice('themeMode', ThemeMode.system, ThemeMode.values),
);

/// In-app alerts when a run finishes or crashes (while the app is open).
final notifyOnFinishProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnFinish', true),
);

final notifyOnCrashProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnCrash', true),
);
