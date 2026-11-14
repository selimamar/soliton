import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../data/providers.dart';
import '../../data/services/api_client.dart';
import '../../data/services/live_updates.dart';
import '../../data/services/server_connection.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';

/// Connect to a Soliton server (the app's "login"), or go back to demo
/// data. The address and token are checked before they are saved.
class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  late final ServerConnection? _initial = ref.read(connectionProvider);
  late final _address = TextEditingController(text: _initial?.address ?? '');
  late final _token = TextEditingController(text: _initial?.token ?? '');
  var _hideToken = true;
  var _checking = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final connection = ServerConnection.parse(_address.text, _token.text);
    if (connection == null) {
      setState(() => _error = 'Enter an address like https://runs.example.com, and the token.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final client = ref.read(apiClientFactoryProvider)(connection);
    String? error;
    try {
      await client.checkSession();
    } on UnauthorizedException {
      error = 'The server rejected this token.';
    } on ServerUnreachableException {
      error =
          "Can't reach ${connection.address}. Check the address, and that the server is running.";
    } on ApiException {
      error = "That address answered, but it doesn't look like a Soliton server.";
    } finally {
      client.close();
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _checking = false;
        _error = error;
      });
      return;
    }
    ref.read(connectionProvider.notifier).connect(connection);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Connected to ${connection.address}')));
    context.go(AppRoutes.runs);
  }

  void _disconnect() {
    ref.read(connectionProvider.notifier).disconnect();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disconnected.')));
    context.go(AppRoutes.runs);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final typed = ServerConnection.parse(_address.text, 'x');

    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth, const EdgeInsets.all(16)),
          children: [
            if (connection != null) ...[
              _ConnectedCard(connection: connection, onDisconnect: _disconnect),
              const SizedBox(height: 24),
            ],
            Text(
              'Run the Soliton server, then enter its address and token. On the server, '
              'print the token with: soliton-server --show-token',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.url],
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Server address',
                hintText: 'https://runs.example.com',
                border: const OutlineInputBorder(),
                helperText: typed != null && typed.isInsecure
                    ? 'Plain http:// sends the token unencrypted. Fine on your own network; '
                          'use https:// anywhere else.'
                    : null,
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              obscureText: _hideToken,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _checking ? null : _connect(),
              decoration: InputDecoration(
                labelText: 'Token',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _hideToken ? 'Show token' : 'Hide token',
                  icon: Icon(
                    _hideToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _hideToken = !_hideToken),
                ),
              ),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _checking ? null : _connect,
              child: _checking
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(connection == null ? 'Connect' : 'Save and reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectedCard extends ConsumerWidget {
  const _ConnectedCard({required this.connection, required this.onDisconnect});

  final ServerConnection connection;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = switch (ref.watch(liveUpdatesProvider)) {
      LiveStatus.live => 'Connected, with live updates',
      LiveStatus.connecting => 'Connecting for live updates…',
      LiveStatus.rejected => 'The server rejected the token',
      LiveStatus.off => 'Not connected',
    };
    return SectionCard(
      title: 'Connected server',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(connection.address, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(status, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onDisconnect, child: const Text('Disconnect')),
        ],
      ),
    );
  }
}
