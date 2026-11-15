import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'data/services/settings_store.dart';
import 'data/services/token_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean web URLs (/runs/x instead of /#/runs/x). No effect on iOS/Android.
  usePathUrlStrategy();
  _registerFontLicenses();

  // Saved settings (theme, server login, ...) are loaded before the first
  // frame, so the app starts with them instead of flickering.
  SettingsStore store;
  try {
    store = await SharedPreferencesStore.load();
  } catch (error) {
    debugPrint('Could not load saved settings ($error); using defaults.');
    store = MemorySettingsStore();
  }
  // The server token is kept apart, in the Keychain or Keystore.
  const tokens = SecureTokenStore();
  final token = await loadServerToken(tokens, store);

  // ProviderScope holds the state of every Riverpod provider in the app.
  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(tokens),
        savedTokenProvider.overrideWithValue(token),
      ],
      child: const SolitonApp(),
    ),
  );
}

/// The bundled fonts' licences, for the licences page. Read only when that
/// page opens.
void _registerFontLicenses() {
  const fonts = {
    'inter': 'Inter',
    'sourceserif4': 'Source Serif 4',
    'jetbrainsmono': 'JetBrains Mono',
    'stixtwotext': 'STIX Two Text',
    'spacegrotesk': 'Space Grotesk',
    'ibmplexmono': 'IBM Plex Mono',
  };
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: file, value: name) in fonts.entries) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/fonts/OFL-$file.txt'));
    }
  });
}
