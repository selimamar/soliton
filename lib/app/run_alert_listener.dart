import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../data/services/live_updates.dart';
import '../features/settings/settings_providers.dart';
import '../models/run.dart';
import 'router.dart';
import 'routes.dart';

/// Shows an alert when a run finishes, crashes or won't finish before its
/// Slurm time limit (if that alert is turned on in Settings), and keeps the
/// live-updates connection running.
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
      final wanted = switch (alert.status) {
        RunStatus.finished => ref.read(notifyOnFinishProvider),
        RunStatus.crashed => ref.read(notifyOnCrashProvider),
        RunStatus.live => alert.timeLimit && ref.read(notifyOnTimeLimitProvider),
        RunStatus.queued => false,
      };
      if (!wanted) return;
      final text = switch (alert.status) {
        RunStatus.finished => '${alert.name} finished',
        _ when alert.timeLimit => "${alert.name} won't finish before its Slurm time limit",
        _ => '${alert.name} crashed${alert.message == null ? '' : ': ${alert.message}'}',
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
