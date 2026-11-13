import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/constants.dart';
import '../../app/routes.dart';
import '../../app/theme.dart';
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
            for (final style in AppStyle.values) _StyleTile(style: style),
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

/// One of the app's styles, with a swatch of its colours; tap to use it.
class _StyleTile extends ConsumerWidget {
  const _StyleTile({required this.style});

  final AppStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appStyleProvider) == style;
    // The swatch shows the style in the brightness on screen now.
    final colors = AppTheme.of(style, Theme.of(context).brightness).colorScheme;
    return ListTile(
      selected: selected,
      leading: _Swatch(colors: colors),
      title: Text(style.label),
      subtitle: Text(style.description),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => ref.read(appStyleProvider.notifier).set(style),
    );
  }
}

/// A style's page, panel and accent colours as three overlapping dots.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color) => Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: colors.outlineVariant),
      ),
    );
    return SizedBox(
      width: 48,
      height: 20,
      child: Stack(
        children: [
          dot(colors.surface),
          Positioned(left: 14, child: dot(colors.surfaceContainerLow)),
          Positioned(left: 28, child: dot(colors.primary)),
        ],
      ),
    );
  }
}
