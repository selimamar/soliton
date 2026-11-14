import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/simulation_info.dart';
import '../../shared/formatters.dart';

/// "t = 6.4", "t = 0.83", "t = 1.5e-6".
String formatSimulatedTime(double t) => 't = ${formatCoordinate(t)}';

/// A step as a time-dependent simulation shows it ("t = 6.4", given its
/// [times]) or a steady solve ("Iteration 37").
String Function(int step) simulationStepLabel(SimulatedTimes? times) => times == null
    ? (step) => 'Iteration ${formatInt(step)}'
    : (step) => formatSimulatedTime(times.at(step));

/// The status to show instead of "Crashed" for a simulation that
/// diverged; null otherwise.
String? simulationStatusLabel(Run run) => run.simulation?.diverged == true ? 'Diverged' : null;

/// One line on where a simulation is: "t = 6.4 of 10 · ~1h 55m left",
/// "Iteration 12 of 100", "Reached t = 300 · 9h 0m", or why it stopped.
String describeSimulation(Run run, DateTime now) {
  final sim = run.simulation!;
  final time = sim.time;
  final remaining = run.estimatedRemainingAt(now);
  String iterations() => run.totalSteps > 0
      ? 'Iteration ${formatInt(run.currentStep)} of ${formatInt(run.totalSteps)}'
      : 'Iteration ${formatInt(run.currentStep)}';
  return switch (run.status) {
    RunStatus.live => [
      if (time != null)
        sim.tEnd == null
            ? formatSimulatedTime(time)
            : '${formatSimulatedTime(time)} of ${formatCoordinate(sim.tEnd!)}'
      else
        iterations(),
      if (remaining != null) '~${formatDuration(remaining)} left',
    ].join(' · '),
    RunStatus.finished => [
      run.statusMessage ??
          (time != null
              ? 'Reached ${formatSimulatedTime(time)}'
              : '${formatInt(run.currentStep)} iterations'),
      formatDuration(run.elapsedAt(now)),
    ].join(' · '),
    RunStatus.crashed => run.statusMessage ?? 'Crashed',
  };
}

/// Each step's simulated time, from the `sim/t` series.
class SimulatedTimes {
  SimulatedTimes._(this._steps, this._times);

  /// Null if no time was logged (a steady solve).
  static SimulatedTimes? from(Map<String, MetricSeries> metrics) {
    final points = [
      for (final p in metrics[SimulationInfo.timeKey]?.points ?? const <MetricPoint>[])
        if (p.value.isFinite) p,
    ];
    if (points.isEmpty) return null;
    return SimulatedTimes._([for (final p in points) p.step], [for (final p in points) p.value]);
  }

  final List<int> _steps;
  final List<double> _times;

  /// The time at [step]: logged there, or interpolated between the steps
  /// around it (held at the ends).
  double at(int step) {
    if (step <= _steps.first) return _times.first;
    if (step >= _steps.last) return _times.last;
    var low = 0, high = _steps.length - 1;
    while (high - low > 1) {
      final mid = (low + high) >> 1;
      if (_steps[mid] <= step) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final span = _steps[high] - _steps[low];
    final f = span == 0 ? 0.0 : (step - _steps[low]) / span;
    return _times[low] + f * (_times[high] - _times[low]);
  }
}

/// A value's name as a title: "kinetic_energy" -> "Kinetic energy",
/// "cfl" -> "CFL number", "sim/dt" -> "Time step".
String describeValue(String name) {
  if (name == SimulationInfo.timeStepKey) return 'Time step';
  if (name.toLowerCase() == 'cfl') return 'CFL number';
  final words = name.split('/').last.replaceAll('_', ' ').trim();
  if (words.isEmpty) return name;
  return words[0].toUpperCase() + words.substring(1);
}
