import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../data/services/live_updates.dart';
import '../features/settings/settings_providers.dart';
import 'router.dart';
import 'routes.dart';

/// Shows an alert when a run finishes, crashes, won't finish before its
/// Slurm time limit, looks unhealthy (a NaN or diverging loss, exploding
/// gradients) or its queued job starts, if that alert is turned on in
/// Settings, and keeps the live-updates connection running.
///
/// These alerts only appear while the app is open. For notifications on a
/// phone when the app is closed, the server can push through ntfy (see
/// server/README.md).
class RunAlertListener extends ConsumerWidget {
  const RunAlertListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Listening (not watching) keeps the connection alive without
    // rebuilding the whole app when its status changes.
    ref.listen(liveUpdatesProvider, (_, _) {});
    ref.listen(runAlertsProvider, (_, alert) {
      if (alert == null) return;
      final wanted = switch (alert.kind) {
        AlertKind.finished => ref.read(notifyOnFinishProvider),
        AlertKind.crashed => ref.read(notifyOnCrashProvider),
        AlertKind.timeLimit => ref.read(notifyOnTimeLimitProvider),
        AlertKind.health => ref.read(notifyOnHealthProvider),
        AlertKind.jobStarted => ref.read(notifyOnJobStartProvider),
      };
      if (!wanted) return;
      final detail = alert.message == null ? '' : ': ${alert.message}';
      final text = switch (alert.kind) {
        AlertKind.finished => '${alert.name} finished',
        AlertKind.crashed => '${alert.name} crashed$detail',
        AlertKind.timeLimit => "${alert.name} won't finish before its Slurm time limit",
        AlertKind.health => '${alert.name} needs a look$detail',
        AlertKind.jobStarted => _started(alert),
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
            duration: const Duration(seconds: 8),
            // With an action, a snack bar would otherwise stay until tapped.
            persist: false,
            action: SnackBarAction(
              label: 'Open',
              onPressed: () => ref.read(routerProvider).go(AppRoutes.run(alert.runId)),
            ),
          ),
        );
    });
    return child;
  }
}

/// "resnet started after 2 h 15 min in the queue", from the server's
/// "Started after 2 h 15 min in the queue."; else "resnet started".
String _started(RunAlert alert) {
  final message = alert.message;
  if (message == null || !message.startsWith('Started ')) return '${alert.name} started';
  final rest = message.substring('Started '.length).replaceAll(RegExp(r'\.$'), '');
  return '${alert.name} started $rest';
}
