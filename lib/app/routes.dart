/// Locations of the app's screens. Navigate with these instead of writing
/// paths by hand. The route tree itself is in `router.dart`.
abstract final class AppRoutes {
  static const runs = '/';
  static const settings = '/settings';

  static String run(String runId) => '/runs/${Uri.encodeComponent(runId)}';
}
