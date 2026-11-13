import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'data/services/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean web URLs (/runs/x instead of /#/runs/x). No effect on iOS/Android.
  usePathUrlStrategy();

  // Saved settings (theme, server login, ...) are loaded before the first
  // frame, so the app starts with them instead of flickering.
  SettingsStore store;
  try {
    store = await SharedPreferencesStore.load();
  } catch (error) {
    debugPrint('Could not load saved settings ($error); using defaults.');
    store = MemorySettingsStore();
  }

  // ProviderScope holds the state of every Riverpod provider in the app.
  runApp(
    ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: const ModelsApp(),
    ),
  );
}
