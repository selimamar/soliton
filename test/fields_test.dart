import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/api_run_repository.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/run_repository.dart';
import 'package:models_app/data/services/server_connection.dart';
import 'package:models_app/features/run_detail/volume/volume_renderer.dart';
import 'package:models_app/features/run_detail/volume/volume_view.dart';
import 'package:models_app/features/run_detail/widgets/field_heatmap.dart';
import 'package:models_app/models/field_snapshot.dart';
import 'package:models_app/shared/formatters.dart';
import 'package:models_app/shared/colormaps.dart';

import 'fake_server.dart';
import 'test_app.dart';

const fno = 'fno-navier-stokes';

/// A tall screen, so whole cards are built (the list is lazy).
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

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
      expect(snapshot.dimensions, 1);
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
      expect(back.shape, [2, 3]);
      for (var i = 0; i < 5; i++) {
        expect(back.prediction[i], closeTo(prediction[i], 2 / 65534));
        expect(back.target![i], closeTo(target[i], 2 / 65534));
      }
      expect(back.prediction[5].isNaN, isTrue);
      expect(snapshot.valueRange, (min: 0.0, max: 2.0));
      expect(snapshot.maxAbsError, closeTo(0.1, 1e-6));
      expect(snapshot.plane(snapshot.error!).values[3], closeTo(-0.1, 1e-6));
    });

    test('refuses data that does not match its shape', () {
      expect(
        () => FieldSnapshot(name: 'u', step: 0, shape: const [2, 2], prediction: Float32List(3)),
        throwsArgumentError,
      );
    });
  });

  group('planes to draw', () {
    // A 2 × 3 × 4 volume whose value is its own index: 100a + 10b + c.
    final volume = Float32List.fromList([
      for (var a = 0; a < 2; a++)
        for (var b = 0; b < 3; b++)
          for (var c = 0; c < 4; c++) 100.0 * a + 10 * b + c,
    ]);
    final snapshot = FieldSnapshot(name: 'v', step: 0, shape: const [2, 3, 4], prediction: volume);

    test('cut a 3D field across each axis', () {
      final across0 = snapshot.plane(volume, axis: 0, index: 1);
      expect((across0.rows, across0.columns), (3, 4));
      expect(across0.values.sublist(0, 2), [100, 101]);
      final across1 = snapshot.plane(volume, axis: 1, index: 2);
      expect((across1.rows, across1.columns), (2, 4));
      expect(across1.values[4], 120, reason: 'row a = 1, column c = 0');
      final across2 = snapshot.plane(volume, axis: 2, index: 3);
      expect((across2.rows, across2.columns), (2, 3));
      expect(across2.values.last, 123);
    });

    test('pick a frame of a rollout, or all of a 1D one as space-time', () {
      final rollout = FieldSnapshot(
        name: 'u',
        step: 0,
        shape: const [3],
        frames: 2,
        times: const [0, 0.5],
        prediction: Float32List.fromList([1, 2, 3, 4, 5, 6]),
      );
      expect(rollout.plane(rollout.prediction, frame: 1).values, [4, 5, 6]);
      final spaceTime = rollout.spaceTime(rollout.prediction);
      expect((spaceTime.rows, spaceTime.columns), (2, 3));
      final back = FieldSnapshot.fromJson(
        jsonDecode(jsonEncode(rollout.toJson())) as Map<String, Object?>,
      );
      expect(back.frames, 2);
      expect(back.times, [0, 0.5]);
    });

    test('refuses frames that do not match the data', () {
      expect(
        () => FieldSnapshot(
          name: 'u',
          step: 0,
          shape: const [3],
          frames: 3,
          prediction: Float32List(6),
        ),
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
    expect(fields.map((f) => f.name).take(6), [
      'vorticity',
      'vorticity, y = 0.5',
      'rollout',
      'rollout, y = 0.5',
      'vorticity (x, y, t)',
      '3D rollout',
    ]);
    expect(
      [
        for (final f in fields)
          if (f.kind == FieldKind.layer) f.layer,
      ],
      ['lifting', 'blocks.0', 'blocks.1', 'blocks.2', 'blocks.3', 'projection'],
    );
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
    final vorticity = (await repository.fetchFields(fno)).first;
    final local = await MockRunRepository(latency: Duration.zero).fetchFields(fno);
    expect(vorticity, local.first);
    expect(await repository.fetchFields(fno), local, reason: 'rollouts, 3D and layers too');
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
        expect(find.text(label), findsWidgets);
      }
      expect(find.text('64 × 64 (of 128 × 128)'), findsOneWidget);
      expect(find.text('x 0 → 1 across, y 0 → 1 down'), findsOneWidget, reason: 'its domain');
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
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      expect(find.text('Tap a map to read the values at a point.'), findsOneWidget);
      await tester.tapAt(tester.getTopLeft(find.byType(FieldHeatmap).first) + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('y = 0.00781, x = 0.00781 · prediction'), findsOneWidget);
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

    testWidgets('a rollout plays frame by frame, with its error per frame', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('rollout'));
      await tester.pumpAndSettle();
      expect(find.text('Rollout: t = 0'), findsOneWidget);
      for (final label in ['Prediction', 'Ground truth', 'Error']) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.byTooltip('Play the rollout'));
      await tester.pump(const Duration(milliseconds: 170));
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.text('Rollout: t = 0.2'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Rollout: t = 0.2'), findsOneWidget, reason: 'paused');
      await tester.scrollUntilVisible(
        find.text('Error along the rollout (step 7,000)'),
        300,
        scrollable: visibleList(),
      );
    });

    testWidgets('a 1D rollout is drawn as space-time maps', (tester) async {
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('rollout, y = 0.5'));
      await tester.pumpAndSettle();
      expect(find.text('Time runs down, from t = 0 to 1.5'), findsOneWidget);
      final map = tester.widget<FieldHeatmap>(find.byType(FieldHeatmap).first);
      expect((map.rows, map.columns, map.markedRow), (16, 128, 0));
    });

    testWidgets('a 3D field is cut in slices, by default across its shortest axis', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('vorticity (x, y, t)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Slices'));
      await tester.pumpAndSettle();
      expect(find.text('3D field: a slice across axis 2'), findsOneWidget);
      expect(find.text('9 of 16'), findsOneWidget, reason: 'the middle slice');
      var map = tester.widget<FieldHeatmap>(find.byType(FieldHeatmap).first);
      expect((map.rows, map.columns), (32, 32));

      await tester.tap(find.text('Axis 0 (32)'));
      await tester.pumpAndSettle();
      map = tester.widget<FieldHeatmap>(find.byType(FieldHeatmap).first);
      expect((map.rows, map.columns), (32, 16));
      await tester.tap(find.byTooltip('Next slice'));
      await tester.pumpAndSettle();
      expect(find.text('18 of 32'), findsOneWidget);
    });

    testWidgets('a 3D field opens in 3D: turn it, change how it is drawn', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('vorticity (x, y, t)'));
      await tester.pumpAndSettle();
      expect(find.byType(VolumeView), findsNWidgets(3));
      expect(find.text('Opacity'), findsOneWidget);
      final reset = find.widgetWithText(TextButton, 'Reset view');
      expect(tester.widget<TextButton>(reset).onPressed, isNull, reason: 'not turned yet');

      final before = tester.widget<VolumeView>(find.byType(VolumeView).first).camera;
      await tester.drag(find.byType(VolumeView).first, const Offset(80, 30));
      await tester.pumpAndSettle();
      final views = tester.widgetList<VolumeView>(find.byType(VolumeView)).toList();
      expect(views.first.camera, isNot(before));
      expect(views.map((v) => v.camera).toSet(), hasLength(1), reason: 'they turn together');
      expect(tester.widget<TextButton>(reset).onPressed, isNotNull);

      await tester.tap(find.text('Surface'));
      await tester.pumpAndSettle();
      expect(find.text('Level'), findsOneWidget);
      expect(find.textContaining('±'), findsWidgets, reason: 'a signed field: both signs');
      expect(
        tester.widget<VolumeView>(find.byType(VolumeView).first).style.mode,
        VolumeMode.isosurface,
      );
      await tester.tap(find.text('Max'));
      await tester.pumpAndSettle();
      expect(find.text('Level'), findsNothing);
      expect(find.text('Opacity'), findsNothing);
    });

    testWidgets('a 3D rollout plays in 3D', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      await tester.tap(find.text('3D rollout'));
      await tester.pumpAndSettle();
      expect(find.byType(VolumeView), findsNWidgets(3));
      expect(find.text('Rollout: t = 0'), findsOneWidget);
      final first = tester.widget<VolumeView>(find.byType(VolumeView).first).volume.values;
      await tester.tap(find.byTooltip('Play the rollout'));
      await tester.pump(const Duration(milliseconds: 170));
      final playing = tester.widget<VolumeView>(find.byType(VolumeView).first);
      expect(playing.draft, isTrue, reason: 'drafts while playing');
      expect(identical(playing.volume.values, first), isFalse, reason: 'the next frame');
      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      expect(tester.widget<VolumeView>(find.byType(VolumeView).first).draft, isFalse);
    });

    testWidgets('the field through the layers, input to output', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, fno);
      await tester.scrollUntilVisible(
        find.text('Inside the model'),
        300,
        scrollable: visibleList(),
      );
      await tester.pumpAndSettle();
      expect(find.text('lifting'), findsOneWidget);
      expect(find.text('blocks.0'), findsOneWidget);
      expect(find.text('Step 7,000'), findsNWidgets(2), reason: 'the snapshot, and the layers');
      // Tap the map itself, not just the name: the map mustn't swallow it.
      final strip = find.ancestor(of: find.text('lifting'), matching: find.byType(ListView));
      await tester.tap(find.descendant(of: strip.first, matching: find.byType(FieldHeatmap)).first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('output 64 × 64 × 32 per sample · mean of 32 channels'),
        200,
        scrollable: visibleList(),
      );
    });

    testWidgets('a 3D layer opens in 3D, or in slices', (tester) async {
      useTallScreen(tester);
      await openFieldsTab(tester, 'fno3d-turbulence');
      await tester.scrollUntilVisible(
        find.text('Inside the model'),
        300,
        scrollable: visibleList(),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('3D output: tap to see it in 3D'),
        findsWidgets,
        reason: 'the tiles say their layer is 3D',
      );
      final volumesBefore = tester.widgetList(find.byType(VolumeView)).length;
      await tester.tap(find.text('blocks.1'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('output 20 × 32 × 32 × 32 per sample · mean of 20 channels · 3D: 32 × 32 × 32'),
        200,
        scrollable: visibleList(),
      );
      await tester.pumpAndSettle();
      expect(tester.widgetList(find.byType(VolumeView)).length, volumesBefore + 1);
      expect(find.text('Output'), findsOneWidget, reason: 'a layer has no truth or error');

      await tester.tap(find.text('Slices').last);
      await tester.pumpAndSettle();
      expect(find.text('Slice 17 of 32 across axis 0'), findsOneWidget);
      await tester.tap(find.text('Axis 2 (32)').last);
      await tester.pumpAndSettle();
      expect(find.text('Slice 17 of 32 across axis 2'), findsOneWidget);
    });

    testWidgets('a link can open a run on its Fields tab', (tester) async {
      await openApp(tester, '/runs/$fno?tab=fields');
      expect(find.text('Step 7,000'), findsOneWidget, reason: 'the Fields tab, straight away');
      await openApp(tester, '/runs/$fno?tab=nonsense');
      expect(find.text('Tags and notes'), findsOneWidget, reason: 'unknown tabs: the Overview');
    });

    testWidgets('a run without fields says how to log them', (tester) async {
      await openFieldsTab(tester, 'resnet50-cifar');
      expect(find.text('This run logs no fields'), findsOneWidget);
    });
  });
}
