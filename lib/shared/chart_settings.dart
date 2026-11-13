import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/settings_store.dart';

// Chart options, saved on the device. Set from `ChartControls`.

/// Loss, learning rate and gradient norm charts on a logarithmic scale.
final logScaleProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('logScale', false),
);

/// What the x-axis of metric charts counts.
enum XAxisUnit { steps, epochs }

final xAxisUnitProvider = NotifierProvider<Setting<XAxisUnit>, XAxisUnit>(
  () => Setting.choice('xAxisUnit', XAxisUnit.steps, XAxisUnit.values),
);
