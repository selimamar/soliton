import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/dataset.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/stat_tile.dart';

/// The Data section: every dataset the server knows about, with its size,
/// where it is, and who made and used it.
class DataScreen extends ConsumerWidget {
  const DataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Image.asset('assets/branding/app_mark.png', width: 24, height: 24),
            ),
            const SizedBox(width: 10),
            const Flexible(child: Text('Data', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.go(AppRoutes.settings),
          ),
        ],
      ),
      body: AsyncValueView(
        value: ref.watch(datasetsProvider),
        onRetry: () => ref.invalidate(datasetsProvider),
        data: (datasets) => _DatasetsList(datasets: datasets),
      ),
    );
  }
}

class _DatasetsList extends ConsumerWidget {
  const _DatasetsList({required this.datasets});

  final List<Dataset> datasets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (datasets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No datasets yet. Register one with modelsapp.register_dataset(path), or every '
            'data file in a folder with `modelsapp data scan FOLDER`. Only their description '
            'is uploaded, not the data.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final bytes = datasets.fold<int>(0, (sum, d) => sum + (d.sizeBytes ?? 0));
    final hosts = {
      for (final d in datasets)
        if (d.host.isNotEmpty) d.host,
    };
    return RefreshIndicator(
      onRefresh: () => ref.refresh(datasetsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatStrip(
                    stats: [
                      ('Datasets', formatInt(datasets.length)),
                      ('Stored', formatBytes(bytes)),
                      ('On', hosts.length == 1 ? hosts.single : '${hosts.length} systems'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final d in datasets) ...[
                    DatasetCard(dataset: d),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "1,200 samples · 64 × 64 × 50 · HDF5".
String describeContents(Dataset d) => [
  if (d.samples case final n?) '${formatInt(n)} ${n == 1 ? 'sample' : 'samples'}',
  if (d.sampleShape case final s? when s.isNotEmpty) s.join(' × '),
  if (d.format.isNotEmpty) d.format,
].join(' · ');

/// A dataset in the list: name, size, contents, where it is, how it was
/// obtained, and who used it.
class DatasetCard extends StatelessWidget {
  const DatasetCard({super.key, required this.dataset});

  final Dataset dataset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = dataset;
    final used = d.usedBy.length;
    final chips = [
      if (d.host.isNotEmpty) d.host,
      if (d.source.isNotEmpty) d.source,
      if (d.madeBy case final m?) 'Made by ${m.name}',
      used == 0 ? 'Not used yet' : (used == 1 ? 'Used by 1 run' : 'Used by $used runs'),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(AppRoutes.dataset(d.id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      d.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (d.sizeBytes case final size?)
                    Text(
                      formatBytes(size),
                      style: theme.textTheme.bodySmall?.copyWith(fontFeatures: AppText.tabular),
                    ),
                ],
              ),
              if (describeContents(d) case final contents when contents.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  contents,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [for (final c in chips) _Tag(text: c)]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
