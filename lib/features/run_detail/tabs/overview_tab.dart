import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/key_value_row.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../widgets/architecture_tree.dart';
import '../widgets/network_diagram.dart';
import '../widgets/run_notes_card.dart';

/// Key facts about a run: size, timing, progress, tags and notes,
/// hyperparameters and architecture.
class OverviewTab extends StatelessWidget {
  const OverviewTab({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    return SpacedListView(
      children: [
        if (run.statusMessage case final message?)
          _StatusBanner(message: message, isError: run.status == RunStatus.crashed),
        _TileRow(
          left: StatTile(
            label: 'Parameters',
            value: formatCount(run.parameterCount),
            icon: Icons.memory,
          ),
          right: StatTile(label: 'Host', value: run.host, icon: Icons.dns_outlined),
        ),
        _TimingTiles(run: run),
        _ProgressCard(run: run),
        RunNotesCard(run: run),
        SectionCard(
          title: 'Hyperparameters',
          child: Column(
            children: [
              for (final entry in run.hyperparameters.entries)
                KeyValueRow(label: entry.key, value: entry.value),
            ],
          ),
        ),
        SectionCard(
          title: 'Architecture · ${run.architecture.type}',
          trailing: Text('${formatCount(run.parameterCount)} params'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NetworkSection(run: run),
              const SizedBox(height: 8),
              ArchitectureTree(root: run.architecture),
            ],
          ),
        ),
      ],
    );
  }
}

/// The network diagram, or what it takes to get one.
class _NetworkSection extends StatelessWidget {
  const _NetworkSection({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final flow = run.flow;
    if (flow == null || !flow.layers.any((layer) => layer.isDrawn)) {
      return Text(
        'The network diagram appears once the model has run with run.watch(model).',
        style: note,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NetworkDiagram(flow: flow, tree: run.architecture),
        const SizedBox(height: 4),
        Text(
          'Layers in the order they run; numbers are output features or channels. '
          'Skip connections aren\'t shown. Hold or hover over a layer for details.',
          style: note,
        ),
      ],
    );
  }
}

/// Elapsed and remaining (or ended) time, kept current by [clockProvider].
class _TimingTiles extends ConsumerWidget {
  const _TimingTiles({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final remaining = run.estimatedRemainingAt(now);
    final endedAt = run.endedAt;

    return _TileRow(
      left: StatTile(
        label: 'Elapsed',
        value: formatDuration(run.elapsedAt(now)),
        icon: Icons.timer_outlined,
      ),
      right: StatTile(
        label: remaining != null ? 'Remaining' : 'Ended',
        value: remaining != null
            ? '~${formatDuration(remaining)}'
            : endedAt != null
            ? formatTimeAgo(endedAt, now: now)
            : '—',
        icon: Icons.hourglass_bottom,
      ),
    );
  }
}

class _TileRow extends StatelessWidget {
  const _TileRow({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Progress',
      trailing: Text(
        formatPercent(run.progress),
        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: run.progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
            color: run.status == RunStatus.crashed ? theme.colorScheme.error : null,
            semanticsLabel: 'Training progress',
            semanticsValue: formatPercent(run.progress),
          ),
          const SizedBox(height: 8),
          Text(
            'Step ${formatInt(run.currentStep)} of ${formatInt(run.totalSteps)} · '
            'epoch ${run.currentEpoch} of ${run.totalEpochs}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground = isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline : Icons.info_outline, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    );
  }
}
