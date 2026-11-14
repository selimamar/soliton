import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/dataset.dart';
import '../../models/field_snapshot.dart';
import '../../shared/clock.dart';
import '../../shared/colormaps.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/key_value_row.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/sparkline.dart';
import '../../shared/widgets/stat_tile.dart';
import '../../shared/widgets/status_chip.dart';
import '../run_detail/system_usage.dart';
import '../run_detail/widgets/field_heatmap.dart';

/// One dataset: its size and contents, a few samples, where it is and how
/// it was made, and the runs that train on it.
class DatasetScreen extends ConsumerWidget {
  const DatasetScreen({super.key, required this.datasetId});

  final String datasetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(datasetProvider(datasetId));
    final loaded = value.value;
    return Scaffold(
      appBar: AppBar(
        title: loaded == null
            ? Text(datasetId)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(loaded.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    [loaded.host, loaded.source].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: AppTheme.headerColorsOf(context).muted),
                  ),
                ],
              ),
      ),
      body: AsyncValueView(
        value: value,
        onRetry: () => ref.invalidate(datasetProvider(datasetId)),
        data: (dataset) => _DatasetPage(dataset: dataset),
      ),
    );
  }
}

class _DatasetPage extends StatelessWidget {
  const _DatasetPage({required this.dataset});

  final Dataset dataset;

  @override
  Widget build(BuildContext context) {
    final d = dataset;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SpacedListView(
      children: [
        StatStrip(
          stats: [
            ('Samples', d.samples == null ? '—' : formatInt(d.samples!)),
            ('Size', d.sizeBytes == null ? '—' : formatBytes(d.sizeBytes!)),
            (
              'Per sample',
              d.sampleShape == null || d.sampleShape!.isEmpty ? '—' : d.sampleShape!.join('×'),
            ),
          ],
          footer: d.splits.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(
                    [for (final e in d.splits.entries) '${e.key} ${formatInt(e.value)}']
                        .join(' · '),
                    style: muted?.copyWith(fontFeatures: AppText.tabular),
                  ),
                ),
        ),
        if (d.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(d.description, style: theme.textTheme.bodyMedium),
          ),
        if (d.variables.isNotEmpty) _Variables(variables: d.variables),
        if (d.previews.isNotEmpty) _Samples(previews: d.previews, total: d.samples),
        _Origin(dataset: d),
        _UsedBy(users: d.usedBy),
      ],
    );
  }
}

/// Each array: its name and meaning, shape and type, and range.
class _Variables extends StatelessWidget {
  const _Variables({required this.variables});

  final List<DatasetVariable> variables;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final mono = AppText.mono(context).copyWith(fontSize: 13);
    return SectionCard(
      title: 'Variables',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, v) in variables.indexed) ...[
            if (i > 0) const Divider(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: v.name, style: mono),
                            if (v.description.isNotEmpty)
                              TextSpan(text: '  ${v.description}', style: muted),
                          ],
                        ),
                      ),
                      if ([
                            if (v.shape case final s?) s.map(formatInt).join(' × '),
                            if (v.dtype.isNotEmpty) v.dtype,
                          ].join(' · ')
                          case final detail when detail.isNotEmpty)
                        Text(detail, style: muted),
                    ],
                  ),
                ),
                if (v.min != null && v.max != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${formatCoordinate(v.min!)} … ${formatCoordinate(v.max!)}'
                    '${v.unit.isEmpty ? '' : ' ${v.unit}'}',
                    style: mono,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A few samples, each on its own colour scale.
class _Samples extends StatelessWidget {
  const _Samples({required this.previews, required this.total});

  final List<FieldSnapshot> previews;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SectionCard(
      title: 'Samples',
      trailing: total == null
          ? null
          : Text('${previews.length} of ${formatInt(total!)}', style: muted),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 560 ? 4 : 2;
          const gap = 8.0;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final p in previews)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Preview(snapshot: p),
                      const SizedBox(height: 4),
                      Text(p.name, style: muted),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.snapshot});

  final FieldSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final range = snapshot.valueRange;
    final plane = snapshot.plane(snapshot.prediction);
    if (snapshot.shape.length == 1) {
      return Sparkline(
        values: plane.values.toList(),
        color: Theme.of(context).colorScheme.onSurface,
        height: 48,
        semanticLabel: snapshot.name,
      );
    }
    return FieldHeatmap(
      data: plane.values,
      rows: plane.rows,
      columns: plane.columns,
      low: range.min,
      high: range.max,
      colormap: Colormap.viridis,
      semanticLabel: snapshot.name,
    );
  }
}

/// Where it is stored, what made it and on what machine, and when the
/// server heard of it.
class _Origin extends ConsumerWidget {
  const _Origin({required this.dataset});

  final Dataset dataset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = dataset;
    final now = ref.watch(clockProvider);
    final machine = d.system == null ? const <(String, String)>[] : describeSystem(d.system!);
    return SectionCard(
      title: 'Where it is and how it was made',
      child: Column(
        children: [
          if (d.location.isNotEmpty) _Location(path: d.location),
          if (d.host.isNotEmpty) KeyValueRow(label: 'Stored on', value: d.host),
          if (d.format.isNotEmpty)
            KeyValueRow(
              label: 'Format',
              value: [
                d.format,
                if (d.files case final n? when n > 1) '${formatInt(n)} files',
              ].join(' · '),
            ),
          if (d.source.isNotEmpty) KeyValueRow(label: 'Source', value: d.source),
          if (d.madeBy case final maker?) _LinkRow(label: 'Made by', user: maker),
          for (final (label, value) in machine.take(2))
            KeyValueRow(label: 'Made on, $label', value: value),
          if (d.fingerprint.isNotEmpty) KeyValueRow(label: 'Fingerprint', value: d.fingerprint),
          if (d.updatedAt case final t?)
            KeyValueRow(
              label: 'Last registered',
              value: formatTimeAgo(t, now: now),
            ),
        ],
      ),
    );
  }
}

/// Where the files are: the whole path, in monospace, selectable to copy.
class _Location extends StatelessWidget {
  const _Location({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Location',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          SelectableText(path, style: AppText.mono(context).copyWith(fontSize: 13)),
        ],
      ),
    );
  }
}

/// A run or simulation a dataset names, opening it on tap.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.user});

  final String label;
  final DatasetUser user;

  @override
  Widget build(BuildContext context) {
    final row = KeyValueRow(
      label: label,
      value: user.status == null ? user.name : '${user.name} ›',
    );
    if (user.status == null) return row;
    return InkWell(
      onTap: () =>
          context.go(user.simulation ? AppRoutes.simulation(user.id) : AppRoutes.run(user.id)),
      child: row,
    );
  }
}

/// The runs (and simulations) that name it in `init(datasets=...)`.
class _UsedBy extends StatelessWidget {
  const _UsedBy({required this.users});

  final List<DatasetUser> users;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SectionCard(
      title: users.isEmpty ? 'Used by' : 'Used by · ${users.length}',
      child: users.isEmpty
          ? Text(
              'No run trains on it yet. Pass it to soliton.init(datasets=[...]) to list the '
              'runs that do here.',
              style: muted,
            )
          : Column(
              children: [
                for (final (i, u) in users.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: u.project.isEmpty ? null : Text(u.project),
                    trailing: u.status == null ? null : StatusChip(status: u.status!),
                    onTap: () =>
                        context.go(u.simulation ? AppRoutes.simulation(u.id) : AppRoutes.run(u.id)),
                  ),
                ],
              ],
            ),
    );
  }
}
