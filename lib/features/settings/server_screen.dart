import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/browser_hint.dart';
import '../../app/routes.dart';
import '../../data/providers.dart';
import '../../data/services/api_client.dart';
import '../../data/services/live_updates.dart';
import '../../data/services/saved_servers.dart';
import '../../data/services/server_connection.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';

/// The Soliton servers the app knows: switch between them, rename or remove
/// them, or add one (its address and token are checked before they are
/// saved). Adding a server already in the list (the same address) replaces
/// its token.
class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _token = TextEditingController();
  var _hideToken = true;
  var _checking = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
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
    } on UnauthorizedException catch (e) {
      error = e.jobToken
          ? "That's the job token, which can only add and update runs and data. Use the "
                "server's main token here (soliton-server --show-token)."
          : 'The server rejected this token.';
    } on ServerUnreachableException {
      error =
          "Can't reach ${connection.address}. Check the address, and that the server is "
          'running.${corsHint()}';
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
    ref.read(serversProvider.notifier).connect(connection, name: _name.text);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Connected to ${connection.address}')));
    context.go(AppRoutes.runs);
  }

  void _disconnect() {
    ref.read(serversProvider.notifier).disconnect();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disconnected.')));
    context.go(AppRoutes.runs);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = ref.watch(serversProvider);
    final typed = ServerConnection.parse(_address.text, 'x');

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth, const EdgeInsets.all(16)),
          children: [
            if (list.servers.isNotEmpty) ...[
              _ServerListCard(list: list, onDisconnect: _disconnect),
              const SizedBox(height: 24),
            ],
            Text(
              list.servers.isEmpty ? 'Connect a server' : 'Add a server',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Run the Soliton server, then enter its address and token. On the server, '
              'print the token with: soliton-server --show-token. A server already in the list '
              '(the same address) gets the new token.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'e.g. Sherlock test, Lab server',
                border: OutlineInputBorder(),
              ),
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
                  : const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The servers the app knows: tap one to show it; rename or remove it from
/// its menu. The current one says how its live updates are doing.
class _ServerListCard extends ConsumerWidget {
  const _ServerListCard({required this.list, required this.onDisconnect});

  final ServerList list;
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
    final servers = ref.read(serversProvider.notifier);
    return SectionCard(
      title: list.servers.length == 1 ? 'Server' : 'Servers',
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (list.servers.length > 1)
            ListTile(
              leading: Icon(
                list.showsAll ? Icons.radio_button_checked : Icons.radio_button_off,
                color: list.showsAll ? theme.colorScheme.primary : null,
              ),
              title: const Text('All servers'),
              subtitle: Text(
                list.showsAll
                    ? 'Every server\'s runs together\n$status'
                    : 'Every server\'s runs together',
              ),
              isThreeLine: list.showsAll,
              onTap: list.showsAll
                  ? null
                  : () {
                      servers.switchTo(ServerList.allId);
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(const SnackBar(content: Text('Showing all servers')));
                    },
            ),
          for (final server in list.servers)
            ListTile(
              leading: Icon(
                server.id == list.currentId ? Icons.radio_button_checked : Icons.radio_button_off,
                color: server.id == list.currentId ? theme.colorScheme.primary : null,
              ),
              title: Text(server.name),
              subtitle: Text(
                server.id == list.currentId ? '${server.address}\n$status' : server.address,
              ),
              isThreeLine: server.id == list.currentId,
              onTap: server.id == list.currentId
                  ? null
                  : () {
                      servers.switchTo(server.id);
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text('Showing ${server.name}')));
                    },
              trailing: PopupMenuButton<String>(
                tooltip: 'More for ${server.name}',
                onSelected: (action) => action == 'rename'
                    ? _rename(context, servers, server)
                    : _remove(context, servers, server),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
            ),
          if (list.currentId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(onPressed: onDisconnect, child: const Text('Disconnect')),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, Servers servers, SavedServer server) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initial: server.name),
    );
    if (name != null) servers.rename(server.id, name);
  }

  Future<void> _remove(BuildContext context, Servers servers, SavedServer server) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text(
          'The app forgets its address and token on this device. Its runs stay on the server.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) servers.remove(server.id);
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename server'),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(context, _name.text), child: const Text('Save')),
    ],
  );
}
