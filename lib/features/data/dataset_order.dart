import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/settings_store.dart';
import '../../models/dataset.dart';
import '../../shared/widgets/group_order.dart';

/// What the Data list is grouped by, saved on the device.
enum DatasetGrouping {
  none('No grouping'),
  project('Project'),
  host('Host'),
  format('Format');

  const DatasetGrouping(this.label);

  final String label;
}

final datasetGroupingProvider = NotifierProvider<Setting<DatasetGrouping>, DatasetGrouping>(
  () => Setting.choice('datasetsGroupBy', DatasetGrouping.none, DatasetGrouping.values),
);

/// What the Data list is ordered by, saved on the device.
enum DatasetOrder {
  newest('Newest first'),
  name('Name, A to Z'),
  size('Largest first'),
  mostUsed('Most used first');

  const DatasetOrder(this.label);

  final String label;
}

final datasetOrderProvider = NotifierProvider<Setting<DatasetOrder>, DatasetOrder>(
  () => Setting.choice('datasetsOrderBy', DatasetOrder.newest, DatasetOrder.values),
);

/// Data groups folded away.
final collapsedDatasetGroupsProvider = NotifierProvider<CollapsedGroups, Set<String>>(
  CollapsedGroups.new,
);

/// [datasets] in [order]. Those without what it orders by (a date, a size)
/// come last; ties keep the order given.
List<Dataset> orderDatasets(List<Dataset> datasets, DatasetOrder order) => switch (order) {
  DatasetOrder.newest => stableSorted(datasets, (a, b) => _laterFirst(_dateOf(a), _dateOf(b))),
  DatasetOrder.name => stableSorted(
    datasets,
    (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
  ),
  DatasetOrder.size => stableSorted(datasets, (a, b) => _largerFirst(a.sizeBytes, b.sizeBytes)),
  DatasetOrder.mostUsed => stableSorted(
    datasets,
    (a, b) => b.usedBy.length.compareTo(a.usedBy.length),
  ),
};

/// [datasets] in groups: by the projects of the runs that made or used it
/// (one group each), its host, or its format.
List<ItemGroup<Dataset>> groupDatasets(List<Dataset> datasets, DatasetGrouping by) => switch (by) {
  DatasetGrouping.none => [ItemGroup(label: '', items: datasets)],
  DatasetGrouping.project => groupItems(
    datasets,
    (d) => [d.madeBy?.project, for (final user in d.usedBy) user.project],
    'Not used by a project',
  ),
  DatasetGrouping.host => groupItems(datasets, (d) => [d.host], 'Unknown host'),
  DatasetGrouping.format => groupItems(datasets, (d) => [d.format], 'Format unknown'),
};

DateTime? _dateOf(Dataset d) => d.updatedAt ?? d.createdAt;

int _laterFirst(DateTime? a, DateTime? b) => switch ((a, b)) {
  (null, null) => 0,
  (null, _) => 1,
  (_, null) => -1,
  (final a?, final b?) => b.compareTo(a),
};

int _largerFirst(int? a, int? b) => switch ((a, b)) {
  (null, null) => 0,
  (null, _) => 1,
  (_, null) => -1,
  (final a?, final b?) => b.compareTo(a),
};
