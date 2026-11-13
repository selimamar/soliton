import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/constants.dart';
import '../../app/routes.dart';
import '../../data/providers.dart';
import '../../shared/widgets/spaced_list_view.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final connection = ref.watch(connectionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth, const EdgeInsets.symmetric(vertical: 8)),
          children: [
            const _SectionHeader('Appearance'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {themeMode},
                onSelectionChanged: (selection) =>
                    ref.read(themeModeProvider.notifier).set(selection.first),
              ),
            ),
            const _SectionHeader('Data source'),
            ListTile(
              leading: Icon(connection == null ? Icons.science_outlined : Icons.dns_outlined),
              title: Text(connection == null ? 'Demo data' : 'Server'),
              subtitle: Text(
                connection == null
                    ? 'Generated runs. Connect to your server to see your own.'
                    : connection.address,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go(AppRoutes.server),
            ),
            const _SectionHeader('Alerts'),
            SwitchListTile(
              secondary: const Icon(Icons.flag_outlined),
              title: const Text('When a run finishes'),
              value: ref.watch(notifyOnFinishProvider),
              onChanged: (v) => ref.read(notifyOnFinishProvider.notifier).set(v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.error_outline),
              title: const Text('When a run crashes'),
              value: ref.watch(notifyOnCrashProvider),
              onChanged: (v) => ref.read(notifyOnCrashProvider.notifier).set(v),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Text(
                'Shown while the app is open. For notifications when it is closed, turn on '
                'ntfy on the server (see the server README).',
              ),
            ),
            const _SectionHeader('About'),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(appName),
              subtitle: Text('Version $appVersion'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
