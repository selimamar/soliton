import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/features/run_detail/widgets/job_times.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/system_info.dart';
import 'package:soliton/shared/formatters.dart';

import 'test_app.dart';

void main() {
  group('formatClock', () {
    final now = DateTime(2026, 11, 14, 10, 30); // A Saturday.
    String clock(DateTime t) =>
        formatClock(t, now: now, timeOfDay: (t) => '${t.hour}:${'${t.minute}'.padLeft(2, '0')}');

    test('says the day only when it isn\'t today', () {
      expect(clock(DateTime(2026, 11, 14, 18, 40)), '18:40');
      expect(clock(DateTime(2026, 11, 15, 2, 10)), 'tomorrow 2:10');
      expect(clock(DateTime(2026, 11, 13, 23, 0)), 'yesterday 23:00');
      expect(clock(DateTime(2026, 11, 17, 14, 20)), 'Tue 14:20');
      expect(clock(DateTime(2026, 11, 27, 9, 5)), 'Nov 27, 9:05');
    });
  });

  test('a short queue wait keeps its seconds; a long one is rounded to the minute', () {
    expect(formatQueueWait(const Duration(seconds: 42)), '42s');
    expect(formatQueueWait(const Duration(minutes: 1, seconds: 48)), '1m 48s');
    expect(formatQueueWait(const Duration(minutes: 44, seconds: 31)), '45m');
    expect(formatQueueWait(const Duration(hours: 3, minutes: 11, seconds: 40)), '3h 12m');
  });

  test('the queue wait is from submitting to Slurm starting the job', () {
    final sample = buildMockRuns(DateTime(2026, 11, 14)).first.run;
    Run withSlurm(Map<String, String> slurm) =>
        Run.fromJson({...sample.toJson(), 'system': SystemInfo(slurm: slurm).toJson()});
    final run = withSlurm({
      'jobId': '1',
      'submitTime': '2026-11-14T15:10:00Z',
      'startTime': '2026-11-14T18:22:00Z',
      'timeLimitAt': '2026-11-15T06:22:00Z',
    });
    expect(run.queueWait, const Duration(hours: 3, minutes: 12));
    expect(run.system!.timeLimitAt, DateTime.utc(2026, 11, 15, 6, 22));
    expect(withSlurm({'jobId': '1'}).queueWait, isNull, reason: 'an older logger');
  });

  group('the Overview', () {
    testWidgets('shows a Slurm run\'s queue wait, finish time and time limit', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      expect(find.byType(JobTimes), findsOneWidget);
      expect(find.text('Queue wait'), findsOneWidget);
      expect(find.text('2h 40m'), findsOneWidget);
      expect(find.text('Finishes'), findsOneWidget);
      expect(find.text('Time limit'), findsOneWidget);
      expect(find.textContaining('Slurm will stop it first'), findsNothing);
    });

    testWidgets('warns when the time limit comes before the end', (tester) async {
      await openApp(tester, '/runs/fno-navier-stokes');
      expect(find.textContaining('Slurm will stop it first'), findsOneWidget);
    });

    testWidgets('keeps only the queue wait once a run has ended', (tester) async {
      await openApp(tester, '/runs/unet-seg');
      await tester.scrollUntilVisible(find.byType(JobTimes), 200, scrollable: visibleList());
      expect(find.text('45m'), findsOneWidget);
      expect(find.text('Finishes'), findsNothing);
      expect(find.text('Time limit'), findsNothing);
    });

    testWidgets('shows a finish time without Slurm too', (tester) async {
      await openApp(tester, '/runs/gpt-tiny');
      expect(find.text('Finishes'), findsOneWidget);
      expect(find.text('Queue wait'), findsNothing);
    });

    testWidgets('of a simulation shows its queue wait too', (tester) async {
      await openApp(tester, '/compute/kelvin-helmholtz-2048');
      expect(find.text('Queue wait'), findsOneWidget);
      expect(find.text('1h 25m'), findsOneWidget);
    });
  });
}
