import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/not_found/not_found_screen.dart';
import '../features/run_detail/run_detail_screen.dart';
import '../features/runs_list/runs_list_screen.dart';
import '../features/settings/settings_screen.dart';

/// All routes of the app (build locations with `AppRoutes`):
///
///   /               runs list
///   /runs/:runId    run detail (Overview, Metrics, Layers tabs)
///   /settings       settings
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
            builder: (context, state) => RunDetailScreen(runId: state.pathParameters['runId']!),
          ),
          GoRoute(path: 'settings', builder: (context, state) => const SettingsScreen()),
        ],
      ),
    ],
    errorBuilder: (context, state) => NotFoundScreen(location: state.uri.toString()),
  );
  ref.onDispose(router.dispose);
  return router;
});
