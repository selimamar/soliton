import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../data/providers.dart';
import '../../../models/run.dart';
import '../../../models/system_info.dart';
import '../../../shared/chart_settings.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/async_value_view.dart';
import '../../../shared/widgets/chart_controls.dart';
import '../../../shared/widgets/key_value_row.dart';
import '../../../shared/widgets/line_chart_card.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../system_usage.dart';
import '../widgets/reproduce_card.dart';

/// What the run trains on (machine, GPUs, software, Slurm job) and how busy
/// it keeps them: GPU use and memory, CPU, memory, GPU temperature and power.
class SystemTab extends ConsumerWidget {
  const SystemTab({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncValueView(
      value: ref.watch(runMetricsProvider(run.id)),
      onRetry: () => ref.invalidate(runMetricsProvider(run.id)),
      data: (metrics) {
        final usage = SystemUsage.from(metrics);
        final info = run.system;
        if (info == null && usage.isEmpty) {
          return _Note(
            'No system information for this ${run.isSimulation ? 'simulation' : 'run'}. '
            'The soliton logger records the machine, its GPUs and their use; update it '
            'to see them here.',
          );
        }
        return SpacedListView(
          children: [
            if (info != null) _Machine(info: info, simulation: run.isSimulation),
            if (info?.repro case final repro?) ReproduceCard(repro: repro),
            if (usage.isEmpty)
              const _Note("GPU, memory and CPU use weren't sampled (system_metrics=False).")
            else ...[
              _LatestTiles(usage: usage, info: info),
              _UsageCharts(run: run, usage: usage),
            ],
          ],
        );
      },
    );
  }
}

/// The machine: "Trained on" for a run, "Runs on" for a simulation.
class _Machine extends StatelessWidget {
  const _Machine({required this.info, required this.simulation});

  final SystemInfo info;
  final bool simulation;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: simulation ? 'Runs on' : 'Trained on',
      child: Column(
        children: [
          for (final (label, value) in describeSystem(info))
            KeyValueRow(label: label, value: value),
        ],
      ),
    );
  }
}

/// The latest sample of each kind, two tiles per row.
class _LatestTiles extends StatelessWidget {
  const _LatestTiles({required this.usage, required this.info});

  final SystemUsage usage;
  final SystemInfo? info;

  @override
  Widget build(BuildContext context) {
    final gpuCount = usage.gpus.length;
    final gpuUse = usage.latestGpuMean('utilization');
    final gpuMemory = usage.latestGpuSum('memory_gb');
    final gpuMemoryTotal = info?.gpuMemoryGb;
    final cpu = usage.cpu?.latest;
    final memoryGb = usage.memoryGb?.latest;
    final memoryTotal = info?.memoryGb;
    final memoryPercent = usage.memory?.latest;

    final tiles = [
      if (gpuUse != null)
        StatTile(
          label: gpuCount > 1 ? 'GPU use (mean of $gpuCount)' : 'GPU use',
          value: formatPercentValue(gpuUse),
          icon: Icons.developer_board,
        ),
      if (gpuMemory != null)
        StatTile(
          label: 'GPU memory',
          value: gpuMemoryTotal == null
              ? formatGb(gpuMemory)
              : '${gpuMemory.toStringAsFixed(1)} / ${formatCapacity(gpuMemoryTotal)}',
          icon: Icons.memory,
        ),
      if (cpu != null && cpu.isFinite)
        StatTile(label: 'CPU', value: formatPercentValue(cpu), icon: Icons.speed),
      if (memoryGb != null && memoryGb.isFinite)
        StatTile(
          label: 'Memory',
          value: memoryTotal == null
              ? formatGb(memoryGb)
              : '${memoryGb.toStringAsFixed(1)} / ${formatCapacity(memoryTotal)}',
          icon: Icons.storage,
        )
      else if (memoryPercent != null && memoryPercent.isFinite)
        StatTile(label: 'Memory', value: formatPercentValue(memoryPercent), icon: Icons.storage),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('Latest', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (var i = 0; i < tiles.length; i += 2)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
            child: Row(
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 12),
                Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox.shrink()),
              ],
            ),
          ),
      ],
    );
  }
}

class _UsageCharts extends ConsumerWidget {
  const _UsageCharts({required this.run, required this.usage});

  final Run run;
  final SystemUsage usage;

  static const _percent = (min: 0.0, max: 100.0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = run.system;
    final epochs = run.totalEpochs > 0 && run.totalSteps > 0;
    final xAxis = epochs && ref.watch(xAxisUnitProvider) == XAxisUnit.epochs
        ? ChartXAxis.epochs(run.totalSteps / run.totalEpochs)
        : const ChartXAxis.steps();
    final perGpuMemory = info == null || info.gpus.isEmpty
        ? null
        : info.gpus.map((g) => g.memoryGb).reduce(math.max);

    List<ChartLine> perGpu(String field) => [
      for (final MapEntry(key: index, value: series) in usage.gpuSeries(field).entries)
        ChartLine(
          label: 'GPU $index',
          color: ChartColors.runs[index % ChartColors.runs.length],
          series: series,
        ),
    ];

    final gpuUse = perGpu('utilization');
    final gpuMemory = perGpu('memory_gb');
    final temperature = perGpu('temperature');
    final power = perGpu('power');
    final cores = info?.cpuCores;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        ChartControls(epochsAvailable: epochs, showLogScale: false),
        if (gpuUse.isNotEmpty)
          LineChartCard(
            title: 'GPU use (%)',
            lines: gpuUse,
            xAxis: xAxis,
            yRange: _percent,
            formatValue: formatPercentValue,
            formatTick: formatPercentValueTick,
          ),
        if (gpuMemory.isNotEmpty)
          LineChartCard(
            title: 'GPU memory (GB)',
            lines: gpuMemory,
            xAxis: xAxis,
            yRange: perGpuMemory != null && perGpuMemory > 0 ? (min: 0.0, max: perGpuMemory) : null,
            formatValue: formatGb,
          ),
        if (usage.cpu case final cpu?)
          LineChartCard(
            title: cores == null ? 'CPU (%)' : 'CPU (% of ${describeCores(cores)})',
            lines: [ChartLine(label: 'CPU', color: ChartColors.train, series: cpu)],
            xAxis: xAxis,
            yRange: _percent,
            formatValue: formatPercentValue,
            formatTick: formatPercentValueTick,
          ),
        if (usage.memoryGb case final memory?)
          LineChartCard(
            title: 'Memory (GB)',
            lines: [ChartLine(label: 'Memory', color: ChartColors.validation, series: memory)],
            xAxis: xAxis,
            yRange: switch (info?.memoryGb) {
              final total? when total > 0 => (min: 0.0, max: total),
              _ => null,
            },
            formatValue: formatGb,
          )
        else if (usage.memory case final memory?)
          LineChartCard(
            title: 'Memory (%)',
            lines: [ChartLine(label: 'Memory', color: ChartColors.validation, series: memory)],
            xAxis: xAxis,
            yRange: _percent,
            formatValue: formatPercentValue,
            formatTick: formatPercentValueTick,
          ),
        if (temperature.isNotEmpty)
          LineChartCard(
            title: 'GPU temperature (°C)',
            height: 140,
            lines: temperature,
            xAxis: xAxis,
            formatValue: (v) => '${v.toStringAsFixed(0)} °C',
          ),
        if (power.isNotEmpty)
          LineChartCard(
            title: 'GPU power (W)',
            height: 140,
            lines: power,
            xAxis: xAxis,
            formatValue: (v) => '${v.toStringAsFixed(0)} W',
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            run.isSimulation
                ? 'Sampled every 15 seconds (by default) while the simulation runs, at the '
                      'step it was at.'
                : 'Sampled every 15 seconds (by default) while the run trains, at the step '
                      'training was at.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(child: Text(text, textAlign: TextAlign.center)),
  );
}
