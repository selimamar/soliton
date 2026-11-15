import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../data/services/api_client.dart';
import '../../shared/widgets/async_value_view.dart';

/// Whether the connected server has a job token: null while not connected,
/// or for a server too old to have them.
final jobTokenProvider = FutureProvider<bool?>((ref) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null) return null;
  final client = ref.watch(apiClientFactoryProvider)(connection);
  try {
    return await client.jobTokenEnabled();
  } finally {
    client.close();
  }
});

/// Settings → Advanced security: a separate token for jobs on clusters,
/// which can only add and update runs and data (what a logger does), so a
/// leaked job script or env file can't read, retag or delete what is on the
/// server. It can still overwrite a run it knows the id of. Off by default: one
/// token for everything. Only while connected to a server.
class JobTokenSection extends ConsumerStatefulWidget {
  const JobTokenSection({super.key});

  @override
  ConsumerState<JobTokenSection> createState() => _JobTokenSectionState();
}

class _JobTokenSectionState extends ConsumerState<JobTokenSection> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(jobTokenProvider);
    final enabled = state.value;
    final supported = !state.isLoading && !state.hasError && enabled != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.key_outlined),
          title: const Text('Separate token for jobs'),
          subtitle: Text(switch (state) {
            AsyncValue(isLoading: true) => 'Checking the server…',
            AsyncValue(hasError: true) => "Couldn't ask the server.",
            _ when enabled == null => 'Needs a newer server.',
            _ =>
              'Jobs get a token that can only add and update runs and data: a leaked job '
                  "script can't read your runs, change tags and notes, or delete anything. The "
                  "server's main token stays on your devices.",
          }),
          value: enabled ?? false,
          onChanged: supported && !_busy ? (on) => on ? _create(replacing: false) : _turnOff() : null,
        ),
        if (enabled ?? false)
          ListTile(
            leading: const Icon(Icons.autorenew),
            title: const Text('New job token'),
            subtitle: const Text('The current one stops working.'),
            enabled: !_busy,
            onTap: () => _create(replacing: true),
          ),
      ],
    );
  }

  Future<void> _create({required bool replacing}) async {
    if (replacing &&
        !await _confirm(
          title: 'Make a new job token?',
          message: 'Jobs using the current one are refused until they use the new one.',
          action: 'Make new token',
        )) {
      return;
    }
    final token = await _call((client) => client.createJobToken());
    if (token == null || !mounted) return;
    await showDialog<void>(context: context, builder: (_) => _JobTokenDialog(token: token));
  }

  Future<void> _turnOff() async {
    if (!await _confirm(
      title: 'Turn off the job token?',
      message:
          "Jobs using it are refused until they use the server's main token again, which "
          'can do everything.',
      action: 'Turn off',
    )) {
      return;
    }
    await _call((client) => client.deleteJobToken().then((_) => true));
  }

  /// Runs [request] against the server; null (after saying why) if it failed.
  Future<T?> _call<T>(Future<T> Function(ApiClient client) request) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return null;
    setState(() => _busy = true);
    final client = ref.read(apiClientFactoryProvider)(connection);
    try {
      return await request(client);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(describeError(error).message)));
      }
      return null;
    } finally {
      client.close();
      ref.invalidate(jobTokenProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;
}

/// The new job token, shown this once (the server keeps only its hash).
class _JobTokenDialog extends StatelessWidget {
  const _JobTokenDialog({required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Job token'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(token, style: AppText.mono(context).copyWith(fontSize: 13)),
            const SizedBox(height: 12),
            const Text(
              'Use it in place of SOLITON_TOKEN on your clusters and in job scripts, for '
              'example in ~/.soliton_env. Then remove the main token from those files: it can '
              'still do everything.',
            ),
            const SizedBox(height: 8),
            Text(
              "It's shown only this once. If you lose it, make a new one.",
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: token)),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
