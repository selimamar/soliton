// Screenshots of the app on demo data, for the website.
//
//   flutter test tool/showcase/capture_test.dart
//   .venv/bin/python tool/showcase/frame.py
//
// Writes raw screens to build/showcase/raw/; frame.py puts them in device
// frames in build/showcase/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_run_repository.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/features/settings/settings_providers.dart';

import '../../test/test_app.dart';

final _root = GlobalKey();

Future<void> _loadFonts() async {
  final fonts = <String, List<String>>{
    'Inter': ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold'],
    'Source Serif 4': ['SourceSerif4-Regular', 'SourceSerif4-Medium'],
    'JetBrains Mono': ['JetBrainsMono-Regular'],
    'STIX Two Text': ['STIXTwoText-400', 'STIXTwoText-400Italic', 'STIXTwoText-500', 'STIXTwoText-600'],
    'Space Grotesk': ['SpaceGrotesk-500'],
    'IBM Plex Mono': ['IBMPlexMono-400', 'IBMPlexMono-500', 'IBMPlexMono-600'],
  };
  ByteData read(String path) => ByteData.sublistView(File(path).readAsBytesSync());
  for (final MapEntry(key: family, value: files) in fonts.entries) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(read('assets/fonts/$f.ttf')));
    }
    await loader.load();
  }
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/Development/flutter';
  final material = '$sdk/bin/cache/artifacts/material_fonts';
  await (FontLoader('MaterialIcons')..addFont(Future.value(read('$material/MaterialIcons-Regular.otf')))).load();
  final roboto = FontLoader('Roboto');
  for (final f in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(Future.value(read('$material/Roboto-$f.ttf')));
  }
  await roboto.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  // Let images decode and charts finish animating.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();
  final boundary = _root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ratio = tester.view.devicePixelRatio;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/showcase/raw/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _open(WidgetTester tester, Size logical, double ratio, ThemeMode mode) async {
  tester.view.physicalSize = logical * ratio;
  tester.view.devicePixelRatio = ratio;
  if (logical.width < 600) {
    // Room for the status bar and home indicator that frame.py draws.
    tester.view.padding = FakeViewPadding(top: 44 * ratio, bottom: 24 * ratio);
    tester.view.viewPadding = FakeViewPadding(top: 44 * ratio, bottom: 24 * ratio);
  }
  addTearDown(tester.view.reset);
  // Demo data, but as if a server were connected, so the runs list has no
  // "Not connected to a server" line. No live updates: nothing goes online.
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: buildApp(
        overrides: [
          runRepositoryProvider.overrideWithValue(MockRunRepository(latency: Duration.zero)),
          connectionProvider.overrideWithValue(
            ServerConnection(baseUri: Uri.parse('https://soliton.example'), token: 'demo'),
          ),
          liveConnectionsProvider.overrideWithValue(const []),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
  containerOf(tester).read(themeModeProvider.notifier).set(mode);
  await tester.pumpAndSettle();
}

Future<void> _go(WidgetTester tester, String location) async {
  routerOf(tester).go(location);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final m = mode.name;

    testWidgets('phone, $m', (tester) async {
      await _open(tester, const Size(393, 852), 3, mode);
      await _shot(tester, 'phone-runs-$m');
      await _go(tester, '/runs/resnet50-cifar');
      await _shot(tester, 'phone-run-$m');
      await tester.tap(find.text('Metrics').first);
      await tester.pumpAndSettle();
      await _shot(tester, 'phone-metrics-$m');
    });

    testWidgets('desktop, $m', (tester) async {
      await _open(tester, const Size(1440, 900), 2, mode);
      await _shot(tester, 'desktop-runs-$m');
      await _go(tester, '/runs/resnet50-cifar');
      await _shot(tester, 'desktop-run-$m');
      await tester.tap(find.text('Metrics').first);
      await tester.pumpAndSettle();
      await _shot(tester, 'desktop-metrics-$m');
      await _go(tester, '/runs/fno-navier-stokes');
      await tester.tap(find.text('Fields').first);
      await tester.pumpAndSettle();
      await _shot(tester, 'desktop-fields-$m');
    });
  }
}
