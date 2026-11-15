import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../tabs/overview_tab.dart' show StatusBanner;

/// When the job ran: how long it waited in Slurm's queue, when it should
/// finish, and its time limit, with a warning when the limit comes first.
/// Whichever is known; nothing if none is. Kept current by [clockProvider].
class JobTimes extends ConsumerWidget {
  const JobTimes({super.key, required this.run});

  final Run run;

  /// Whether there's anything to show (so a list leaves no gap for it).
  static bool showsFor(Run run) =>
      run.queueWait != null ||
      run.liveTimeLimitAt != null ||
      run.estimatedRemainingAt(DateTime.now()) != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final wait = run.queueWait;
    final finish = run.estimatedEndAt(now);
    final limit = run.liveTimeLimitAt;
    if (wait == null && finish == null && limit == null) return const SizedBox.shrink();

    String clock(DateTime t) => formatClock(t, now: now, timeOfDay: (t) => timeOfDay(context, t));
    final stats = [
      if (wait != null) ('Queue wait', formatRoughDuration(wait)),
      if (finish != null) ('Finishes', '~${clock(finish)}'),
      if (limit != null) ('Time limit', clock(limit)),
    ];
    final cutShort = finish != null && limit != null && finish.isAfter(limit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatStrip(stats: stats),
        if (cutShort) ...[
          const SizedBox(height: 8),
          StatusBanner(
            message:
                'At this pace it finishes around ${clock(finish)}, after its time limit '
                'at ${clock(limit)}: Slurm will stop it first.',
            isError: false,
          ),
        ],
      ],
    );
  }
}

/// "18:40" or "6:40 PM", as the device writes times.
String timeOfDay(BuildContext context, DateTime time) => MaterialLocalizations.of(context)
    .formatTimeOfDay(
      TimeOfDay.fromDateTime(time),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
