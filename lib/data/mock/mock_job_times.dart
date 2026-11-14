import '../../models/system_info.dart';

/// [system] with its Slurm job's times, as the logger records them: it was
/// submitted [queued] before [startedAt], and its time limit is [timeLimit]
/// after. Unchanged without either.
SystemInfo? withJobTimes(
  SystemInfo? system,
  DateTime startedAt, {
  Duration? queued,
  Duration? timeLimit,
}) {
  if (system == null || (queued == null && timeLimit == null)) return system;
  String utc(DateTime t) => t.toUtc().toIso8601String();
  return SystemInfo.fromJson({
    ...system.toJson(),
    'slurm': {
      ...system.slurm,
      if (queued != null) 'submitTime': utc(startedAt.subtract(queued)),
      'startTime': utc(startedAt),
      if (timeLimit != null) 'timeLimitAt': utc(startedAt.add(timeLimit)),
    },
  });
}
