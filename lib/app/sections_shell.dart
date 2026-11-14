import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'routes.dart';

/// The app's sections, switched between at the bottom of a phone's screen
/// or down the side of a wider one: Runs (training), Compute (simulations)
/// and Data (datasets). Screens opened from them (a run, settings, ...) cover it.
class SectionsShell extends StatelessWidget {
  const SectionsShell({super.key, required this.location, required this.child});

  /// The current path, to know which section is open.
  final String location;
  final Widget child;

  /// Widest screen with the bar at the bottom; wider ones get a side rail.
  static const railWidth = 840.0;

  static const _sections = [
    (route: AppRoutes.runs, label: 'Runs', icon: Icons.show_chart, selected: Icons.show_chart),
    (route: AppRoutes.compute, label: 'Compute', icon: Icons.waves_outlined, selected: Icons.waves),
    (route: AppRoutes.data, label: 'Data', icon: Icons.storage_outlined, selected: Icons.storage),
  ];

  @override
  Widget build(BuildContext context) {
    final index = location.startsWith(AppRoutes.compute)
        ? 1
        : location.startsWith(AppRoutes.data)
        ? 2
        : 0;
    void open(int i) {
      if (i != index) context.go(_sections[i].route);
    }

    final scheme = Theme.of(context).colorScheme;
    final hairline = BorderSide(color: scheme.outlineVariant);
    if (MediaQuery.sizeOf(context).width >= railWidth) {
      return Scaffold(
        body: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(border: Border(right: hairline)),
              child: NavigationRail(
                selectedIndex: index,
                onDestinationSelected: open,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final s in _sections)
                    NavigationRailDestination(
                      icon: Icon(s.icon),
                      selectedIcon: Icon(s.selected),
                      label: Text(s.label),
                    ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: hairline)),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: open,
          destinations: [
            for (final s in _sections)
              NavigationDestination(
                icon: Icon(s.icon),
                selectedIcon: Icon(s.selected),
                label: s.label,
              ),
          ],
        ),
      ),
    );
  }
}
