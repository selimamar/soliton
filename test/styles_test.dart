import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/app/theme.dart';
import 'package:models_app/features/settings/settings_providers.dart';

import 'test_app.dart';

void main() {
  // Each style has its own fonts, some wider than others (Lab's lettering
  // is monospace): every screen must still fit a phone in each.
  for (final style in AppStyle.values) {
    testWidgets('every screen fits a phone in the ${style.label} style', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await openApp(tester);
      containerOf(tester).read(appStyleProvider.notifier).set(style);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'runs list');

      Future<void> visit(String location) async {
        routerOf(tester).go(location);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: location);
        // Scroll down the page, so everything on it gets laid out.
        for (var i = 0; i < 6; i++) {
          final lists = find
              .byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)
              .hitTestable();
          if (lists.evaluate().isEmpty) break;
          await tester.drag(lists.first, const Offset(0, -600));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$location, scrolled');
        }
      }

      for (final location in [
        '/settings',
        '/settings/server',
        '/sweep',
        '/compare?runs=resnet50-cifar,unet-seg',
      ]) {
        await visit(location);
      }
      for (final id in ['resnet50-cifar', 'unet-seg', 'fno-navier-stokes', 'fno3d-turbulence']) {
        for (final tab in ['overview', 'metrics', 'layers', 'fields', 'system']) {
          await visit('/runs/$id?tab=$tab');
        }
      }
    });
  }
}
