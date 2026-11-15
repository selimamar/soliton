import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../data/services/settings_store.dart';

// App settings, saved on the device (see `Setting`). The server login is
// `connectionProvider` in data/providers.dart; chart options are in
// shared/chart_settings.dart.

final themeModeProvider = NotifierProvider<Setting<ThemeMode>, ThemeMode>(
  () => Setting.choice('themeMode', ThemeMode.system, ThemeMode.values),
);

/// The app's look (colours, title font, corners); see [AppStyle].
final appStyleProvider = NotifierProvider<Setting<AppStyle>, AppStyle>(
  () => Setting.choice('appStyle', AppStyle.paper, AppStyle.values),
);

/// In-app alerts when a run finishes or crashes (while the app is open).
final notifyOnFinishProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnFinish', true),
);

final notifyOnCrashProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnCrash', true),
);

/// In-app alerts when a live run, at its pace, won't finish before its
/// Slurm job's time limit (the server says so once per job).
final notifyOnTimeLimitProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnTimeLimit', true),
);

/// In-app alerts when the logger sees training go wrong: a NaN or
/// diverging loss, exploding gradients.
final notifyOnHealthProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnHealth', true),
);

/// In-app alerts when a queued Slurm job starts (one queued with
/// `soliton sbatch`, or one that waited at least 10 minutes).
final notifyOnJobStartProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('notifyOnJobStart', true),
);
