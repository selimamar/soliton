import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/api_run_repository.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/run_repository.dart';
import 'package:models_app/data/services/server_connection.dart';
import 'package:models_app/features/run_detail/tabs/fields_tab.dart';
import 'package:models_app/features/run_detail/widgets/field_heatmap.dart';
import 'package:models_app/models/field_snapshot.dart';
import 'package:models_app/shared/colormaps.dart';

import 'fake_server.dart';
import 'test_app.dart';

const fno = 'fno-navier-stokes';

Future<void> openFieldsTab(WidgetTester tester, String runId) async {
  await openApp(tester, '/runs/$runId');
  await tester.tap(find.text('Fields'));
  await tester.pumpAndSettle();
}

void main() {
  group('FieldSnapshot', () {
    test('reads the 16-bit format the logger sends', () {
      // Codes 0, 65534 and NaN, little-endian, between -1 and 3.
      final bytes = ByteData(6)
        ..setUint16(0, 0, Endian.little)
        ..setUint16(2, 65534, Endian.little)
        ..setUint16(4, 65535, Endian.little);
      final data = base64.encode(bytes.buffer.asUint8List());
      final snapshot = FieldSnapshot.fromJson({
        'name': 'u',
        'step': 10,
        'shape': [3],
        'originalShape': [300],
        'min': -1,
        'max': 3,
        'prediction': data,
        'target': null,
        'stats': {'relL2': 'NaN'},
      });
      expect(snapshot.prediction.sublist(0, 2), [-1, 3]);
      expect(snapshot.prediction[2].isNaN, isTrue);
      expect(snapshot.originalShape, [300]);
      expect(snapshot.is2D, isFalse);
      expect(snapshot.error, isNull);
      expect(snapshot.stats['relL2']!.isNaN, isTrue);
    });

    test('round-trips through JSON within one quantization step', () {
      final prediction = Float32List.fromList([0, 0.5, 1, 1.5, 2, double.nan]);
      final target = Float32List.fromList([0, 0.4, 1, 1.6, 2, 1]);
      final snapshot = FieldSnapshot(
        name: 'p',
        step: 3,
        shape: const [2, 3],
        prediction: prediction,
        target: target,
      );
      final back = FieldSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
      );
      expect(back.rows, 2);
      expect(back.columns, 3);
      for (var i = 0; i < 5; i++) {
        expect(back.prediction[i], closeTo(prediction[i], 2 / 65534));
        expect(back.target![i], closeTo(target[i], 2 / 65534));
      }
      expect(back.prediction[5].isNaN, isTrue);
      expect(snapshot.valueRange, (min: 0.0, max: 2.0));
      expect(snapshot.maxAbsError, closeTo(0.1, 1e-6));
      expect(snapshot.at(snapshot.error!, 1, 0), closeTo(-0.1, 1e-6));
    });

    test('refuses data that does not match its shape', () {
      expect(
        () => FieldSnapshot(name: 'u', step: 0, shape: const [2, 2], prediction: Float32List(3)),
        throwsArgumentError,
      );
    });
  });

  test('relative errors keep their digits', () {
    expect(formatRelativeError(0.0321), '3.2%');
    expect(formatRelativeError(0.00456), '0.46%');
    expect(formatRelativeError(0.0000312), '0.0031%');
    expect(formatRelativeError(double.nan), 'NaN');
  });

  test('colour maps run from their first to their last colour', () {
    for (final map in [Colormap.viridis, Colormap.diverging]) {
      expect(map.at(0), map.anchors.first);
      expect(map.at(1), map.anchors.last);
      expect(map.at(-5), map.anchors.first, reason: 'clamped');
    }
    expect(Colormap.diverging.at(0.5), const Color(0xFFF7F7F7), reason: 'white at zero');
  });

  test('the demo operator learns: its error falls over training', () async {
    final fields = await MockRunRepository(latency: Duration.zero).fetchFields(fno);
    expect(fields.map((f) => f.name), ['vorticity', 'vorticity, y = 0.5']);
    expect(fields.first.shape, [64, 64]);
    final errors = [for (final s in fields.first.steps) s.relL2!];
    expect(errors.first, greaterThan(0.5));
    expect(errors.last, lessThan(0.1));
    expect(errors.last, lessThan(errors[errors.length ~/ 2]));
  });

  test('runs without fields have none', () async {
    expect(await MockRunRepository(latency: Duration.zero).fetchFields('resnet50-cifar'), isEmpty);
  });

  test('fields and snapshots from the server', () async {
    final server = FakeServer(runIds: {fno});
    final repository = ApiRunRepository(
      server.clientFor(ServerConnection.parse('http://localhost:8000', 'secret')!),
    );
    final [vorticity, _] = await repository.fetchFields(fno);
    final local = await MockRunRepository(latency: Duration.zero).fetchFields(fno);
    expect(vorticity, local.first);
    final step = vorticity.steps.last.step;
    final snapshot = await repository.fetchFieldSnapshot(fno, 'vorticity', step);
    expect(snapshot.step, step);
    expect(snapshot.shape, [64, 64]);
    expect(snapshot.target, isNotNull);
    await expectLater(
      repository.fetchFieldSnapshot(fno, 'vorticity', step + 1),
      throwsA(isA<FieldNotFoundException>()),
    );
  });

  group('Fields tab', () {
    testWidgets('shows the latest snapshot as three maps', (tester) async {
      await openFieldsTab(tester, fno);
      expect(find.text('Step 7,000'), findsOneWidget);
      expect(find.text('Latest of 15'), findsOneWidget);
      expect(find.byType(FieldHeatmap), findsNWidgets(3));
      for (final label in ['Prediction', 'Ground truth', 'Error', 'Relative L2', 'RMSE']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('64 × 64 (of 128 × 128)'), findsOneWidget);
    });

    testWidgets('steps back through training', (tester) async {
      await openFieldsTab(tester, fno);
      await tester.tap(find.byTooltip('Previous snapshot'));
      await tester.pumpAndSettle();
      expect(find.text('Step 6,500'), findsOneWidget);
      expect(find.text('14 of 15'), findsOneWidget);

      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(find.text('Step 0'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left)).onPressed,
        isNull,
      );
    });

    testWidgets('tapping a map reads the values there', (tester) async {
      await openFieldsTab(tester, fno);
      expect(find.text('Tap a map to read the values at a point.'), findsOneWidget);
      await tester.tapAt(tester.getTopLeft(find.byType(FieldHeatmap).first) + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Row 0, column 0 · prediction'), findsOneWidget);
      expect(find.textContaining('· truth '), findsOneWidget);
    });

    testWidgets('a 1D field is drawn as lines', (tester) async {
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('vorticity, y = 0.5'));
      await tester.pumpAndSettle();
      expect(find.byType(FieldHeatmap), findsNothing);
      expect(find.text('Prediction and ground truth'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Error (prediction − truth)'),
        200,
        scrollable: visibleList(),
      );
    });

    testWidgets('a run without fields says how to log them', (tester) async {
      await openFieldsTab(tester, 'resnet50-cifar');
      expect(find.text('This run logs no fields'), findsOneWidget);
    });
  });
}
