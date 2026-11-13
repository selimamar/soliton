import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/compare/compare_screen.dart';
import '../features/not_found/not_found_screen.dart';
import '../features/run_detail/run_detail_screen.dart';
import '../features/runs_list/runs_list_screen.dart';
import '../features/settings/server_screen.dart';
import '../features/settings/settings_screen.dart';

/// All routes of the app (build locations with `AppRoutes`):
///
///   /                     runs list
///   /runs/:runId          run detail; ?tab=metrics (or layers, fields,
///                         system) opens on that tab
///   /compare?runs=a,b     runs side by side
///   /settings             settings
///   /settings/server      connect to a server
///
/// Any other path shows [NotFoundScreen].
final routerProvider = Provider<GoRouter>((ref) {
  // Don't `ref.watch` other providers in here: a rebuild would create a new
  // GoRouter and reset the navigation stack. For rules such as "log in
  // first", use `redirect` with `refreshListenable` and read state with
  // `ref.read` instead.
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const RunsListScreen(),
        routes: [
          GoRoute(
            path: 'runs/:runId',
            builder: (context, state) => RunDetailScreen(
              runId: state.pathParameters['runId']!,
              initialTab:
                  RunTab.values.asNameMap()[state.uri.queryParameters['tab']] ?? RunTab.overview,
            ),
          ),
          GoRoute(
            path: 'compare',
            builder: (context, state) => CompareScreen(
              runIds: [
                for (final id in (state.uri.queryParameters['runs'] ?? '').split(','))
                  if (id.isNotEmpty) id,
              ],
            ),
          ),
          GoRoute(
            path: 'settings',
            builder: (context, state) => const SettingsScreen(),
            routes: [GoRoute(path: 'server', builder: (context, state) => const ServerScreen())],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => NotFoundScreen(location: state.uri.toString()),
  );
  ref.onDispose(router.dispose);
  return router;
});
