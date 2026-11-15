import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/providers.dart';
import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/widgets/async_value_view.dart' show describeError;
import '../tabs/overview_tab.dart' show StatusBanner;

/// Asks a live run to stop, after confirming: its script saves what it
/// needs and stops at its next `run.should_stop()` check (a script that
/// doesn't check is stopped as by scancel). Nothing once it was asked, or
/// for a run that isn't live.
class StopButton extends ConsumerWidget {
  const StopButton({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (run.status != RunStatus.live || run.stopRequestedAt != null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.stop_circle_outlined),
      tooltip: 'Stop',
      onPressed: () => _stop(context, ref),
    );
  }

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop ${run.name}?'),
        content: const Text(
          'Its script stops at its next run.should_stop() check, after saving what it needs '
          '(a checkpoint, say), and the run ends as "Stopped from the app". The logger hears of '
          'it within seconds while the run logs. A script that doesn\'t check should_stop() is '
          'stopped as by scancel.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stop')),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      await ref.read(runStopperProvider).stop(run.id);
      message = 'Asked ${run.name} to stop';
    } catch (error) {
      message = "Couldn't ask ${run.name} to stop: ${describeError(error).title}";
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// A banner while a run is asked to stop (see [stopRequestedText]).
class StopRequestedBanner extends ConsumerWidget {
  const StopRequestedBanner({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (stopRequestedText(run, ref.watch(clockProvider))) {
        final text? => StatusBanner(message: text, isError: false),
        null => const SizedBox.shrink(),
      };
}

/// While a run is asked to stop: since when, and what happens next.
String? stopRequestedText(Run run, DateTime now) {
  final asked = run.stopRequestedAt;
  if (asked == null || run.status != RunStatus.live) return null;
  final minutes = now.difference(asked).inMinutes;
  final when = minutes < 1 ? 'just now' : '$minutes min ago';
  return 'Asked to stop $when. It stops at its script\'s next run.should_stop() check '
      '(or as by scancel if the script doesn\'t check).';
}
