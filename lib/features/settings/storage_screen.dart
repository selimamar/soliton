import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../data/combined_run_repository.dart';
import '../../data/providers.dart';
import '../../data/services/api_client.dart';
import '../../data/services/saved_servers.dart';
import '../../data/services/server_connection.dart';
import '../../models/run.dart';
import '../../models/storage_report.dart';
import '../../shared/clock.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';

/// The servers the Storage screen covers: the one shown, or each saved one
/// in "All servers".
final storageServersProvider = Provider<List<(SavedServer, ServerConnection)>>((ref) {
  final list = ref.watch(serversProvider);
  if (list.showsAll) return list.connections;
  return switch ((list.current, list.connection)) {
    (final server?, final connection?) => [(server, connection)],
    _ => const [],
  };
});

/// What a server stores, by run (`GET /api/storage`).
final storageProvider = FutureProvider.autoDispose.family<StorageReport, String>((
  ref,
  serverId,
) async {
  final list = ref.watch(serversProvider);
  final server = list.servers.firstWhere((s) => s.id == serverId);
  final connection = list.connectionFor(server);
  if (connection == null) throw StateError('No token for ${server.name}');
  final client = ref.watch(apiClientFactoryProvider)(connection);
  try {
    return await client.storage();
  } finally {
    client.close();
  }
});

/// Settings → Storage: how much space each server's runs take, and thinning
/// out old ones (each curve keeps as many points as the charts show, each
/// field its latest snapshot) to keep it in check.
class StorageScreen extends ConsumerWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(storageServersProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth, const EdgeInsets.all(16)),
          children: [
            Text(
              'The server keeps everything a run logged. Thinning an ended run keeps as many '
              'points per curve as its charts show, and the latest snapshot of each field: it '
              'looks the same here, but soliton.runs() no longer gets every point, and older '
              "snapshots are gone. It can't be undone.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (servers.isEmpty) const Text('Connect a server to see what it stores.'),
            for (final (server, _) in servers) ...[
              _ServerStorage(
                server: server,
                named: servers.length > 1,
                combinedIds: ref.watch(serversProvider).showsAll,
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _ServerStorage extends ConsumerStatefulWidget {
  const _ServerStorage({required this.server, required this.named, required this.combinedIds});

  final SavedServer server;

  /// Several servers on screen: say which this is.
  final bool named;

  /// In "All servers", run ids carry their server's.
  final bool combinedIds;

  @override
  ConsumerState<_ServerStorage> createState() => _ServerStorageState();
}

class _ServerStorageState extends ConsumerState<_ServerStorage> {
  static const shown = 8;
  var _busy = false;
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(storageProvider(widget.server.id));
    return AsyncValueView<StorageReport>(
      value: report,
      onRetry: () => ref.invalidate(storageProvider(widget.server.id)),
      data: (report) => _card(context, report),
    );
  }

  Widget _card(BuildContext context, StorageReport report) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final thinned = report.runs.where((r) => r.thinnedAt != null).length;
    final runs = _all ? report.runs : report.runs.take(shown).toList();
    return SectionCard(
      title: widget.named ? widget.server.name : 'Database',
      trailing: Text(
        report.bytes == null ? 'size unknown' : formatBytes(report.bytes!),
        style: theme.textTheme.titleSmall,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [
              '${report.runs.length} ${report.runs.length == 1 ? 'run' : 'runs'}',
              if (thinned > 0) '$thinned thinned',
              if (report.canCompact) '${formatBytes(report.free!)} can be given back to the disk',
            ].join(' · '),
            style: muted,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.compress, size: 18),
                label: const Text('Thin old runs…'),
                onPressed: _busy ? null : () => _thinOlder(report),
              ),
              if (report.canCompact)
                OutlinedButton.icon(
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: Text('Give back ${formatBytes(report.free!)}'),
                  onPressed: _busy ? null : () => _compact(report),
                ),
            ],
          ),
          if (report.runs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Largest runs', style: theme.textTheme.titleSmall),
            for (final run in runs)
              _RunRow(
                run: run,
                share: report.runs.first.bytes == 0 ? 0 : run.bytes / report.runs.first.bytes,
                busy: _busy,
                onOpen: () => _open(run),
                onThin: () => _thinRun(run, report.thinPoints),
              ),
            if (report.runs.length > shown)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(_all ? 'Show fewer' : 'Show all ${report.runs.length} runs'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _open(RunStorage run) {
    final id = widget.combinedIds
        ? CombinedRunRepository.combinedId(widget.server.id, run.runId)
        : run.runId;
    context.go(run.simulation ? AppRoutes.simulation(id) : AppRoutes.run(id));
  }

  Future<void> _thinRun(RunStorage run, int thinPoints) async {
    if (!await _confirm(
      title: 'Thin out ${run.name}?',
      message:
          'Each curve keeps ${formatInt(thinPoints)} points (as many as its charts show) and '
          'each field its latest snapshot. It looks the same in the app, but soliton.runs() no '
          "longer gets every point it logged, and older snapshots are gone. This can't be undone.",
      action: 'Thin out',
    )) {
      return;
    }
    final freed = await _call((client) => client.thinRun(run.runId));
    if (freed != null) _say('${run.name} thinned: about ${formatBytes(freed)} freed.');
  }

  Future<void> _thinOlder(StorageReport report) async {
    final days = await showDialog<int>(
      context: context,
      builder: (_) => _ThinOlderDialog(report: report, now: ref.read(clockProvider)),
    );
    if (days == null) return;
    final result = await _call((client) => client.thinOlder(days));
    if (result case (final count, final freed)) {
      _say(
        count == 0
            ? 'Nothing to thin.'
            : '$count ${count == 1 ? 'run' : 'runs'} thinned: about ${formatBytes(freed)} freed.',
      );
    }
  }

  Future<void> _compact(StorageReport report) async {
    if (!await _confirm(
      title: 'Give the space back?',
      message:
          'Space freed by deleting or thinning runs is reused by new data, but the database '
          'file keeps its size until it is rewritten. Rewriting it gives about '
          '${formatBytes(report.free!)} back to the disk. Uploads wait while it runs, which can '
          'take a minute on a large database; nothing is lost.',
      action: 'Give back',
    )) {
      return;
    }
    final sizes = await _call((client) => client.compact());
    if (sizes case (final before?, final after?)) {
      _say('Database ${formatBytes(before)} → ${formatBytes(after)}.');
    }
  }

  Future<T?> _call<T>(Future<T> Function(ApiClient client) action) async {
    final list = ref.read(serversProvider);
    final connection = list.connectionFor(widget.server);
    if (connection == null) return null;
    setState(() => _busy = true);
    final client = ref.read(apiClientFactoryProvider)(connection);
    try {
      return await action(client);
    } catch (error) {
      if (mounted) _say(describeError(error).message);
      return null;
    } finally {
      client.close();
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(storageProvider(widget.server.id));
      }
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
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

/// One run: its name, what it keeps, a bar of its size against the largest,
/// and a button to thin it out (an ended run with something to thin).
class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.run,
    required this.share,
    required this.busy,
    required this.onOpen,
    required this.onThin,
  });

  final RunStorage run;
  final double share;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onThin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final facts = [
      '${formatCount(run.points)} points',
      if (run.snapshots > 0) '${run.snapshots} ${run.snapshots == 1 ? 'snapshot' : 'snapshots'}',
      if (run.thinnedAt != null) 'thinned',
      if (!run.ended) run.status == RunStatus.queued ? 'queued' : 'running',
    ].join(' · ');
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          run.name,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatBytes(run.bytes), style: theme.textTheme.bodyMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // The size is written next to the name: the bar only shows it.
                  ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: share.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: run.thinnedAt != null ? scheme.outline : scheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(facts, style: muted, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (run.thinnable)
              IconButton(
                icon: const Icon(Icons.compress),
                tooltip: 'Thin out ${run.name}',
                onPressed: busy ? null : onThin,
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}

/// Picks how old a run must be to be thinned, showing how many that is.
class _ThinOlderDialog extends StatefulWidget {
  const _ThinOlderDialog({required this.report, required this.now});

  final StorageReport report;
  final DateTime now;

  @override
  State<_ThinOlderDialog> createState() => _ThinOlderDialogState();
}

class _ThinOlderDialogState extends State<_ThinOlderDialog> {
  static const choices = [7, 30, 90, 365];
  var _days = 30;

  List<RunStorage> get _matching => [
    for (final run in widget.report.runs)
      if (run.thinnedAt == null &&
          run.thinnable &&
          run.endedAt != null &&
          widget.now.difference(run.endedAt!) > Duration(days: _days))
        run,
  ];

  @override
  Widget build(BuildContext context) {
    final matching = _matching;
    final bytes = matching.fold(0, (sum, run) => sum + run.bytes);
    return AlertDialog(
      title: const Text('Thin old runs'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Thin every run that ended more than:'),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: [
              for (final days in choices)
                ButtonSegment(value: days, label: Text(days == 365 ? '1 year' : '$days days')),
            ],
            selected: {_days},
            showSelectedIcon: false,
            onSelectionChanged: (picked) => setState(() => _days = picked.single),
          ),
          const SizedBox(height: 12),
          Text(
            matching.isEmpty
                ? 'No run that old has anything to thin.'
                : '${matching.length} ${matching.length == 1 ? 'run' : 'runs'}, taking '
                      '${formatBytes(bytes)} now. Each keeps '
                      '${formatInt(widget.report.thinPoints)} points per curve and its latest '
                      "field snapshots. This can't be undone.",
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: matching.isEmpty ? null : () => Navigator.pop(context, _days),
          child: Text(matching.isEmpty ? 'Thin' : 'Thin ${matching.length}'),
        ),
      ],
    );
  }
}
