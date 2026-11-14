/// The latest lines a run's script printed (its output and errors, with the
/// traceback if it crashed), as the logger sent them.
class RunOutput {
  const RunOutput({required this.lines, required this.total});

  factory RunOutput.fromJson(Map<String, Object?> json) {
    final lines = [for (final line in (json['lines'] as List?) ?? const []) line as String];
    return RunOutput(
      lines: List.unmodifiable(lines),
      total: (json['total'] as num?)?.toInt() ?? lines.length,
    );
  }

  static const empty = RunOutput(lines: [], total: 0);

  /// The latest lines, oldest first; the server keeps the last 1,000.
  final List<String> lines;

  /// How many lines the script printed in all.
  final int total;

  /// Lines printed before [lines] that the server no longer has.
  int get dropped => total - lines.length;

  Map<String, Object?> toJson() => {'lines': lines, 'total': total};
}
