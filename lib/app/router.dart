import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show GlobalKey, NavigatorState;

import '../features/compare/compare_screen.dart';
import '../features/data/data_screen.dart';
import '../features/data/dataset_screen.dart';
import '../features/compute/simulation_screen.dart';
import '../features/compute/simulations_screen.dart';
import '../features/farm/farm_screen.dart';
import '../features/not_found/not_found_screen.dart';
import '../features/run_detail/run_detail_screen.dart';
import '../features/runs_list/runs_list_screen.dart';
import '../features/settings/server_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/storage_screen.dart';
import '../features/sweep/sweep_screen.dart';
import 'sections_shell.dart';

/// All routes of the app (build locations with `AppRoutes`):
///
///   /                     runs list
///   /runs/:runId          run detail; ?tab=metrics (or layers, fields,
///                         system) opens on that tab
///   /compare?runs=a,b     runs side by side
///   /sweep                runs of a project by hyperparameters or metrics
///   /farm                 runs as ducks (finished) and eggs (live)
///   /settings             settings
///   /settings/server      connect to a server
///   /settings/storage     space runs take, thinning old ones
///   /compute              simulations
///   /compute/:id          a simulation; ?tab=diagnostics (or fields,
///                         system) opens on that tab
///   /data                 datasets
///   /data/:id             a dataset
///
/// The runs list, the simulations and the datasets share a shell that switches between
/// them; every other screen covers it.
/// Any other path shows [NotFoundScreen].
final routerProvider = Provider<GoRouter>((ref) {
  // Don't `ref.watch` other providers in here: a rebuild would create a new
  // GoRouter and reset the navigation stack. For rules such as "log in
  // first", use `redirect` with `refreshListenable` and read state with
  // `ref.read` instead.
  final root = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: root,
    routes: [
      ShellRoute(
        builder: (context, state, child) => SectionsShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const RunsListScreen(),
            routes: [
              GoRoute(
                parentNavigatorKey: root,
                path: 'runs/:runId',
                builder: (context, state) => RunDetailScreen(
                  runId: state.pathParameters['runId']!,
                  initialTab:
                      RunTab.values.asNameMap()[state.uri.queryParameters['tab']] ??
                      RunTab.overview,
                ),
              ),
              GoRoute(
                parentNavigatorKey: root,
                path: 'compare',
                builder: (context, state) => CompareScreen(
                  runIds: [
                    for (final id in (state.uri.queryParameters['runs'] ?? '').split(','))
                      if (id.isNotEmpty) id,
                  ],
                ),
              ),
              GoRoute(
                parentNavigatorKey: root,
                path: 'sweep',
                builder: (context, state) => const SweepScreen(),
              ),
              GoRoute(
                parentNavigatorKey: root,
                path: 'farm',
                builder: (context, state) => const FarmScreen(),
              ),
              GoRoute(
                parentNavigatorKey: root,
                path: 'settings',
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  GoRoute(
                    parentNavigatorKey: root,
                    path: 'server',
                    builder: (context, state) => const ServerScreen(),
                  ),
                  GoRoute(
                    parentNavigatorKey: root,
                    path: 'storage',
                    builder: (context, state) => const StorageScreen(),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/data',
            builder: (context, state) => const DataScreen(),
            routes: [
              GoRoute(
                parentNavigatorKey: root,
                path: ':datasetId',
                builder: (context, state) =>
                    DatasetScreen(datasetId: state.pathParameters['datasetId']!),
              ),
            ],
          ),
          GoRoute(
            path: '/compute',
            builder: (context, state) => const SimulationsScreen(),
            routes: [
              GoRoute(
                parentNavigatorKey: root,
                path: ':simulationId',
                builder: (context, state) => SimulationScreen(
                  simulationId: state.pathParameters['simulationId']!,
                  initialTab:
                      SimulationTab.values.asNameMap()[state.uri.queryParameters['tab']] ??
                      SimulationTab.overview,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => NotFoundScreen(location: state.uri.toString()),
  );
  ref.onDispose(router.dispose);
  return router;
});
