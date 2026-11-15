import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../shared/redirect.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/delete_dialog.dart';
import '../../shared/widgets/status_chip.dart';
import 'tabs/fields_tab.dart';
import 'tabs/layers_tab.dart';
import 'tabs/metrics_tab.dart';
import 'tabs/overview_tab.dart';
import 'tabs/system_tab.dart';
import 'widgets/stop_button.dart';

/// The run detail tabs, in order; their names are what `?tab=` takes in a
/// run's link (e.g. `/runs/fno-navier-stokes?tab=fields`).
enum RunTab { overview, metrics, layers, fields, system }

/// One run, split into five tabs: Overview, Metrics, Layers, Fields and
/// System.
class RunDetailScreen extends ConsumerWidget {
  const RunDetailScreen({super.key, required this.runId, this.initialTab = RunTab.overview});

  final String runId;

  /// The tab to open on.
  final RunTab initialTab;

  /// Narrowest screen on which the tabs share the width equally.
  static const _fixedTabsWidth = 520.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(runProvider(runId));
    final loadedRun = run.value;
    // A simulation's link under /runs (typed, or an old bookmark) opens it
    // in Compute, where its own tabs are.
    if (loadedRun != null && loadedRun.isSimulation) {
      // The same tab where there is one: a simulation's Diagnostics are its
      // Metrics.
      final tab = switch (initialTab) {
        RunTab.overview || RunTab.layers => null,
        RunTab.metrics => 'diagnostics',
        RunTab.fields => 'fields',
        RunTab.system => 'system',
      };
      final page = AppRoutes.simulation(runId);
      goAfterFrame(context, tab == null ? page : '$page?tab=$tab');
      return const Scaffold();
    }

    return DefaultTabController(
      // A link to another tab of the same run switches to it.
      key: ValueKey(initialTab),
      length: RunTab.values.length,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: loadedRun == null
              ? Text(runId)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loadedRun.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [loadedRun.host, loadedRun.project].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: AppTheme.headerColorsOf(context).muted),
                    ),
                  ],
                ),
          actions: [
            if (loadedRun != null) ...[
              StatusChip(status: loadedRun.status, inHeader: true),
              const SizedBox(width: 4),
              StopButton(run: loadedRun),
              DeleteButton(
                kind: DeleteKind.run,
                item: (
                  id: loadedRun.id,
                  name: loadedRun.name,
                  live: loadedRun.status == RunStatus.live,
                ),
                then: AppRoutes.runs,
              ),
              const SizedBox(width: 4),
            ],
          ],
          // Tabs only make sense once there is a run to show.
          bottom: loadedRun == null
              ? null
              : TabBar(
                  // Five fixed tabs don't fit their labels on a phone: scroll
                  // there, fill the width on larger screens.
                  isScrollable: MediaQuery.sizeOf(context).width < _fixedTabsWidth,
                  tabAlignment: MediaQuery.sizeOf(context).width < _fixedTabsWidth
                      ? TabAlignment.start
                      : TabAlignment.fill,
                  tabs: [
                    for (final name in ['Overview', 'Metrics', 'Layers', 'Fields', 'System'])
                      // Lab labels its tabs in capitals, like panel buttons.
                      AppTheme.styleOf(context) == AppStyle.lab
                          ? Tab(child: Text(name.toUpperCase(), semanticsLabel: name))
                          : Tab(text: name),
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
              KeepAliveTab(child: OverviewTab(run: run)),
              KeepAliveTab(child: MetricsTab(runId: run.id)),
              KeepAliveTab(child: LayersTab(runId: run.id)),
              KeepAliveTab(child: FieldsTab(runId: run.id)),
              KeepAliveTab(child: SystemTab(run: run)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps a tab alive while it is off screen, so switching tabs keeps its
/// scroll position and doesn't refetch its (auto-disposed) data.
class KeepAliveTab extends StatefulWidget {
  const KeepAliveTab({super.key, required this.child});

  final Widget child;

  @override
  State<KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<KeepAliveTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
