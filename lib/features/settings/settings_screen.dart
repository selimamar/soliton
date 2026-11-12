import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/constants.dart';
import '../../shared/widgets/spaced_list_view.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final backendUrl = ref.watch(backendUrlProvider);

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
            const ListTile(
              leading: Icon(Icons.science_outlined),
              title: Text('Demo data'),
              subtitle: Text('The app shows generated runs until a server is connected.'),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server address'),
              subtitle: Text(backendUrl.isEmpty ? 'Not set' : backendUrl),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editBackendUrl(context, ref, backendUrl),
            ),
            const _SectionHeader('Notifications'),
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
            const _SectionHeader('About'),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(appName),
              subtitle: Text('Version $appVersion (first draft)'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editBackendUrl(BuildContext context, WidgetRef ref, String current) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _BackendUrlDialog(initialValue: current),
    );
    if (result != null) ref.read(backendUrlProvider.notifier).set(result);
  }
}

/// Text-field dialog. Stateful so it owns (and disposes) its controller.
class _BackendUrlDialog extends StatefulWidget {
  const _BackendUrlDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_BackendUrlDialog> createState() => _BackendUrlDialogState();
}

class _BackendUrlDialogState extends State<_BackendUrlDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server address'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'https://my-server.example.com'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
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
