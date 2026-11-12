import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

// App settings. They live in memory for now; persisting them (e.g. with
// shared_preferences) is a later step.

/// One in-memory setting: its value, plus [set] to change it.
class Setting<T> extends Notifier<T> {
  Setting(this._initial);

  final T _initial;

  @override
  T build() => _initial;

  void set(T value) => state = value;
}

final themeModeProvider = NotifierProvider<Setting<ThemeMode>, ThemeMode>(
  () => Setting(ThemeMode.system),
);

/// Address of the backend server. Not used yet: the app runs on demo data.
final backendUrlProvider = NotifierProvider<Setting<String>, String>(() => Setting(''));

final notifyOnFinishProvider = NotifierProvider<Setting<bool>, bool>(() => Setting(true));

final notifyOnCrashProvider = NotifierProvider<Setting<bool>, bool>(() => Setting(true));
