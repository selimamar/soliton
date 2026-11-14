import 'run.dart';
import 'system_info.dart';

/// What a run's machine costs per hour, roughly: the price the run logged
/// (`soliton.init(price_per_hour=...)`), else a typical on-demand cloud
/// price for its GPUs (or CPU cores). An estimate, to be shown rounded.
class HourlyPrice {
  const HourlyPrice({required this.dollars, required this.basis, this.logged = false});

  /// US dollars per hour for the whole job (all its GPUs).
  final double dollars;

  /// Where [dollars] comes from, to show under the figure, e.g. "1 × H100
  /// at a typical cloud price".
  final String basis;

  /// Set by the run rather than estimated here.
  final bool logged;

  /// Null when there is nothing to go on (no system information, a GPU
  /// that isn't in [gpuPrices], no core count), or the run logged a price
  /// of zero (a machine it doesn't pay for).
  static HourlyPrice? of(SystemInfo? info) {
    if (info == null) return null;
    if (info.pricePerHour case final price?) {
      return price > 0 ? HourlyPrice(dollars: price, basis: 'set by the run', logged: true) : null;
    }
    if (info.gpus.isNotEmpty) {
      final counts = <String, int>{};
      var dollars = 0.0;
      for (final gpu in info.gpus) {
        final match = gpuPriceOf(gpu.name);
        if (match == null) return null;
        dollars += match.$2;
        counts[match.$1] = (counts[match.$1] ?? 0) + 1;
      }
      final gpus = [for (final e in counts.entries) '${e.value} × ${e.key}'].join(' + ');
      return HourlyPrice(dollars: dollars, basis: '$gpus at a typical cloud price');
    }
    if (info.cpuCores case final cores? when cores > 0) {
      final count = cores == cores.roundToDouble() ? '${cores.round()}' : '$cores';
      return HourlyPrice(
        dollars: cores * corePrice,
        basis: '$count CPU ${cores == 1 ? 'core' : 'cores'} at a typical cloud price',
      );
    }
    return null;
  }
}

/// Typical on-demand cloud prices per GPU-hour in US dollars (late 2026),
/// rounded: between the big clouds' and the GPU clouds' list prices.
/// Matched against the GPU's name in this order, so `H200` is tried
/// before `H100` and `L40S` before `L40`.
const gpuPrices = <(String, double)>[
  ('B200', 7),
  ('H200', 5),
  ('H100', 4),
  ('A100', 2.5),
  ('L40S', 1.5),
  ('L40', 1.2),
  ('A10G', 1),
  ('A10', 0.8),
  ('A6000', 0.8),
  ('A40', 0.6),
  ('L4', 0.8),
  ('V100', 2.5),
  ('P100', 1.5),
  ('T4', 0.4),
  // Workstation and consumer GPUs (common on university clusters, e.g.
  // Sherlock's RTX 2080 Ti and TITANs), at GPU-cloud rental prices.
  ('A5000', 0.4),
  ('A4000', 0.3),
  ('4090', 0.5),
  ('RTX 3090', 0.3),
  ('RTX 2080', 0.2),
  ('TITAN', 0.2),
];

/// A CPU core-hour (a general-purpose cloud vCPU), in US dollars.
const corePrice = 0.05;

/// The [gpuPrices] entry for a GPU named e.g. `NVIDIA A100-SXM4-80GB`:
/// (`A100`, 2.5). A model counts only as a whole word (`H100 80GB`,
/// `A100-SXM4`), so `A10` isn't `A100` or `A10G`.
(String, double)? gpuPriceOf(String name) {
  final upper = name.toUpperCase();
  for (final entry in gpuPrices) {
    final at = RegExp('(^|[^A-Z0-9])${entry.$1}(\$|[^A-Z0-9])').firstMatch(upper);
    if (at != null) return entry;
  }
  return null;
}

/// What [run] has cost so far, as of [now], and what it will have cost
/// when it ends (live runs only, at its pace so far), in US dollars.
({double soFar, double? total})? estimateCost(Run run, DateTime now, [HourlyPrice? price]) {
  final hourly = price ?? HourlyPrice.of(run.system);
  if (hourly == null) return null;
  double cost(Duration d) => hourly.dollars * d.inSeconds / 3600;
  final elapsed = run.elapsedAt(now);
  final remaining = run.estimatedRemainingAt(now);
  return (soFar: cost(elapsed), total: remaining == null ? null : cost(elapsed + remaining));
}
