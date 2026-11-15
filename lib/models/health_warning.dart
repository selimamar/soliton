/// What went wrong in training (see the logger's `_health.py`): a loss
/// turned NaN or infinite, a training loss climbed back up, or a gradient
/// norm blew up.
enum HealthKind {
  nan('Loss is NaN'),
  divergence('Loss diverging'),
  gradient('Gradients blew up');

  const HealthKind(this.label);

  /// A short title, e.g. "Loss is NaN".
  final String label;
}

/// A training problem the logger saw in a run, once per kind and job.
class HealthWarning {
  const HealthWarning({required this.kind, required this.step, required this.message, this.at});

  /// Null for a kind this app doesn't know (from a newer logger).
  static HealthWarning? fromJson(Map<String, Object?> json) {
    final kind = HealthKind.values.asNameMap()[json['kind']];
    final step = json['step'];
    final message = json['message'];
    if (kind == null || step is! num || message is! String) return null;
    return HealthWarning(
      kind: kind,
      step: step.toInt(),
      message: message,
      at: switch (json['at']) {
        final String s => DateTime.tryParse(s),
        _ => null,
      },
    );
  }

  final HealthKind kind;
  final int step;

  /// E.g. "train/loss is NaN at step 1,234".
  final String message;
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'step': step,
    'message': message,
    'at': at?.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is HealthWarning &&
      other.kind == kind &&
      other.step == step &&
      other.message == message &&
      other.at == at;

  @override
  int get hashCode => Object.hash(kind, step, message, at);
}
