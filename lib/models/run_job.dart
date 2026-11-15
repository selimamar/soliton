import 'run.dart';

/// One process (usually a Slurm job) that ran a run: a run continued from a
/// checkpoint in later jobs has several, in order.
class RunJob {
  const RunJob({
    this.jobId,
    this.submittedAt,
    required this.startedAt,
    this.endedAt,
    this.status,
    this.message,
    required this.startStep,
    this.endStep,
  });

  factory RunJob.fromJson(Map<String, Object?> json) => RunJob(
    jobId: json['jobId'] as String?,
    submittedAt: _time(json['submittedAt']),
    startedAt: _time(json['startedAt'])!,
    endedAt: _time(json['endedAt']),
    status: RunStatus.values.asNameMap()[json['status']],
    message: json['message'] as String?,
    startStep: (json['startStep'] as num?)?.toInt() ?? 0,
    endStep: (json['endStep'] as num?)?.toInt(),
  );

  /// The Slurm job id, if it was one.
  final String? jobId;
  final DateTime? submittedAt;
  final DateTime startedAt;

  /// Null while it runs.
  final DateTime? endedAt;

  /// How it ended (finished or crashed); null while it runs.
  final RunStatus? status;
  final String? message;

  /// The run's step when this job took over, and when it ended.
  final int startStep;
  final int? endStep;

  /// How long it waited in Slurm's queue, if known.
  Duration? get queueWait => switch (submittedAt) {
    final submitted? when !startedAt.isBefore(submitted) => startedAt.difference(submitted),
    _ => null,
  };

  Duration ranFor(DateTime now) => (endedAt ?? now).difference(startedAt);

  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'submittedAt': submittedAt?.toIso8601String(),
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'status': status?.name,
    'message': message,
    'startStep': startStep,
    'endStep': endStep,
  };

  @override
  bool operator ==(Object other) =>
      other is RunJob &&
      other.jobId == jobId &&
      other.submittedAt == submittedAt &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt &&
      other.status == status &&
      other.message == message &&
      other.startStep == startStep &&
      other.endStep == endStep;

  @override
  int get hashCode =>
      Object.hash(jobId, submittedAt, startedAt, endedAt, status, message, startStep, endStep);

  static DateTime? _time(Object? value) => value is String ? DateTime.tryParse(value) : null;
}
