import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../data/providers.dart';

/// One quiet line while no server is connected, with a way to connect one:
/// "Not connected to a server." (the lists are empty for that reason), or,
/// with demo data on, that what is shown is made up. Nothing once connected.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(connectionProvider) != null) return const SizedBox.shrink();
    final demoData = ref.watch(demoDataProvider);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(demoData ? Icons.science_outlined : Icons.cloud_off_outlined, size: 16, color: muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            demoData ? 'Demo data. Everything here is made up.' : 'Not connected to a server.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        TextButton(
          onPressed: () => context.go(AppRoutes.server),
          child: const Text('Connect server'),
        ),
      ],
    );
  }
}
