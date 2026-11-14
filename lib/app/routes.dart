/// Locations of the app's screens. Navigate with these instead of writing
/// paths by hand. The route tree itself is in `router.dart`.
abstract final class AppRoutes {
  static const runs = '/';
  static const settings = '/settings';
  static const server = '/settings/server';

  /// Runs of a project side by side by what they varied.
  static const sweep = '/sweep';

  /// The runs as ducks and eggs on a farm.
  static const farm = '/farm';

  /// The Compute section: simulations.
  static const compute = '/compute';

  /// The Data section: datasets.
  static const data = '/data';

  /// A dataset's page, e.g. `/data/ns2d-vorticity-v3`.
  static String dataset(String id) => '/data/${Uri.encodeComponent(id)}';

  static String run(String runId) => '/runs/${Uri.encodeComponent(runId)}';

  /// A simulation's page, e.g. `/compute/kelvin-helmholtz-2048`.
  static String simulation(String id) => '/compute/${Uri.encodeComponent(id)}';

  /// The compare screen for [runIds], e.g. `/compare?runs=a,b`.
  static String compare(Iterable<String> runIds) =>
      Uri(path: '/compare', queryParameters: {'runs': runIds.join(',')}).toString();
}
