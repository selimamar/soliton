import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/features/settings/settings_providers.dart';

import 'test_app.dart';

Future<void> expectGuidelines(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('runs list meets accessibility guidelines (${mode.name})', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester);
      containerOf(tester).read(themeModeProvider.notifier).set(mode);
      await tester.pumpAndSettle();

      await expectGuidelines(tester);
      handle.dispose();
    });

    testWidgets('run overview meets accessibility guidelines (${mode.name})', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester, '/runs/unet-seg');
      containerOf(tester).read(themeModeProvider.notifier).set(mode);
      await tester.pumpAndSettle();

      await expectGuidelines(tester);
      handle.dispose();
    });
  }

  for (final location in ['/settings/server', '/compare?runs=resnet50-cifar,unet-seg']) {
    testWidgets('$location meets accessibility guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester, location);
      await expectGuidelines(tester);
      handle.dispose();
    });
  }

  testWidgets('a picked run card says it is selected', (tester) async {
    final handle = tester.ensureSemantics();
    await openApp(tester);
    await tester.tap(find.byTooltip('Compare runs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('resnet50-cifar'));
    await tester.pumpAndSettle();
    final card = tester.getSemantics(find.text('resnet50-cifar')).getSemanticsData();
    expect(card.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('a run card is one button that reads its content', (tester) async {
    final handle = tester.ensureSemantics();
    await openApp(tester);

    // The text, the sparkline and the progress bar all merge into the card.
    final card = tester.getSemantics(find.text('resnet50-cifar')).getSemanticsData();
    expect(card.flagsCollection.isButton, isTrue);
    expect(card.hasAction(SemanticsAction.tap), isTrue);
    expect(
      card.label,
      allOf(contains('resnet50-cifar'), contains('Live'), contains('Loss curve, falling')),
    );
    expect(card.label, contains('Training progress'));
    handle.dispose();
  });

  testWidgets('charts on the Metrics tab have labels', (tester) async {
    final handle = tester.ensureSemantics();
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.tap(find.text('Metrics'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(RegExp(r'^Loss chart\. Train: latest')), findsOneWidget);
    handle.dispose();
  });
}
