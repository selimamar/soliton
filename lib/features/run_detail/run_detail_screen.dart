import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/providers.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/status_chip.dart';
import 'tabs/layers_tab.dart';
import 'tabs/metrics_tab.dart';
import 'tabs/overview_tab.dart';
import 'tabs/system_tab.dart';

/// One run, split into four tabs: Overview, Metrics, Layers and System.
class RunDetailScreen extends ConsumerWidget {
  const RunDetailScreen({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(runProvider(runId));
    final loadedRun = run.value;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(loadedRun?.name ?? runId),
          actions: [
            if (loadedRun != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: StatusChip(status: loadedRun.status),
              ),
          ],
          // Tabs only make sense once there is a run to show.
          bottom: loadedRun == null
              ? null
              : const TabBar(
                  tabs: [
                    Tab(text: 'Overview'),
                    Tab(text: 'Metrics'),
                    Tab(text: 'Layers'),
                    Tab(text: 'System'),
                  ],
                ),
        ),
        body: AsyncValueView(
          value: run,
          onRetry: () => ref.invalidate(runProvider(runId)),
          data: (run) => TabBarView(
            // No swiping between tabs: switch with the tab bar instead.
            // Otherwise a horizontal drag on a chart (to read its values)
            // would switch tabs: the tab view claims the drag after 18 px,
            // before the chart's own recognizer (36 px) gets a chance.
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _KeepAlive(child: OverviewTab(run: run)),
              _KeepAlive(child: MetricsTab(runId: run.id)),
              _KeepAlive(child: LayersTab(runId: run.id)),
              _KeepAlive(child: SystemTab(run: run)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps a tab alive while it is off screen, so switching tabs keeps its
/// scroll position and doesn't refetch its (auto-disposed) data.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
