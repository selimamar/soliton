/// Locations of the app's screens. Navigate with these instead of writing
/// paths by hand. The route tree itself is in `router.dart`.
abstract final class AppRoutes {
  static const runs = '/';
  static const settings = '/settings';
  static const server = '/settings/server';

  static String run(String runId) => '/runs/${Uri.encodeComponent(runId)}';

  /// The compare screen for [runIds], e.g. `/compare?runs=a,b`.
  static String compare(Iterable<String> runIds) =>
      Uri(path: '/compare', queryParameters: {'runs': runIds.join(',')}).toString();
}
