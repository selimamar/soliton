import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/features/run_detail/widgets/jobs_card.dart';
import 'package:soliton/features/run_detail/widgets/reproduce_card.dart';
import 'package:soliton/models/run_job.dart';
import 'package:soliton/models/system_info.dart';
import 'package:soliton/shared/widgets/line_chart_card.dart';

import 'test_app.dart';

void main() {
  group('a run continued over several jobs', () {
    testWidgets('lists each job on its Overview', (tester) async {
      await openApp(tester, '/runs/fno3d-turbulence');
      await tester.scrollUntilVisible(find.byType(JobsCard), 200, scrollable: visibleList());
      expect(find.text('Jobs'), findsOneWidget);
      expect(find.textContaining('3 jobs'), findsOneWidget);
      expect(find.text('Job 2 · 52203940'), findsOneWidget);
      expect(find.textContaining('Stopped by its Slurm time limit'), findsNWidgets(2));
      expect(find.textContaining('running for'), findsOneWidget, reason: 'the third still runs');
    });

    testWidgets('marks where each later job took over on its charts', (tester) async {
      await openApp(tester, '/runs/fno3d-turbulence?tab=metrics');
      final chart = tester.widget<LineChartCard>(find.byType(LineChartCard).first);
      expect(chart.marks, hasLength(2));
    });

    test('a job\'s queue wait and how long it ran', () {
      final job = RunJob.fromJson({
        'jobId': '1',
        'submittedAt': '2026-11-14T08:00:00Z',
        'startedAt': '2026-11-14T08:20:00Z',
        'endedAt': '2026-11-14T10:20:00Z',
        'status': 'crashed',
        'startStep': 0,
        'endStep': 500,
      });
      expect(job.queueWait, const Duration(minutes: 20));
      expect(job.ranFor(DateTime.utc(2030)), const Duration(hours: 2));
      expect(RunJob.fromJson(job.toJson()), job);
    });
  });

  group('reproduce', () {
    test('the command to rerun, from where it ran', () {
      const repro = ReproInfo(
        cwd: '/home/me/my project',
        command: 'python3 train.py',
        commit: '045e08c302bf',
        dirty: ['train.py'],
      );
      expect(repro.rerun, "cd '/home/me/my project' && python3 train.py");
      expect(repro.codeVersion, '045e08c + changes');
      expect(ReproInfo.fromJson(repro.toJson()), repro);
    });

    testWidgets('the System tab shows the code, the command and the job script', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar?tab=system');
      await tester.scrollUntilVisible(find.byType(ReproduceCard), 200, scrollable: visibleList());
      expect(find.text('Reproduce'), findsOneWidget);
      expect(find.text('4c1d8a2 on main'), findsOneWidget);
      expect(find.textContaining('Uncommitted changes in 2 files'), findsOneWidget);
      expect(find.text('python3 train.py --model resnet --epochs 100'), findsOneWidget);

      // Clear of the bottom bar.
      await tester.scrollUntilVisible(
        find.text('Copy command to rerun'),
        100,
        scrollable: visibleList(),
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Copy command to rerun')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy command to rerun'));
      await tester.pump();
      expect(find.text('Copied the command'), findsOneWidget);

      await tester.tap(find.text('Job script'));
      await tester.pumpAndSettle();
      expect(find.textContaining('#SBATCH --partition=gpu'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('it isn\'t on the Overview', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      expect(find.byType(ReproduceCard), findsNothing);
    });
  });
}
