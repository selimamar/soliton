import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/board_providers.dart';
import '../../data/services/saved_servers.dart';
import '../../models/board_card.dart';
import '../../models/dataset.dart';
import '../../models/run.dart';
import '../../shared/widgets/async_value_view.dart';

/// Asks for a new card's title (and project, column and server), adds it,
/// and returns its key; null if cancelled or saving failed (with a message).
Future<String?> showNewCardDialog(
  BuildContext context,
  WidgetRef ref, {
  String? project,
  BoardColumn column = BoardColumn.todo,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final board = ref.read(boardProvider.notifier);
  final homes = board.homes;
  if (homes.isEmpty) return null;
  final result = await showDialog<_NewCard>(
    context: context,
    builder: (_) => _NewCardDialog(
      project: project,
      column: column,
      projects: ref.read(boardProvider).value?.projects ?? const [],
      homes: homes,
    ),
  );
  if (result == null) return null;
  try {
    final placed = await board.add(
      server: result.server,
      title: result.title,
      project: result.project,
      column: result.column,
    );
    return placed.key;
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't add the card. ${describeError(error).message}")),
    );
    return null;
  }
}

typedef _NewCard = ({String title, String project, BoardColumn column, SavedServer? server});

class _NewCardDialog extends StatefulWidget {
  const _NewCardDialog({
    required this.project,
    required this.column,
    required this.projects,
    required this.homes,
  });

  /// Given when adding from a lane: then only the title is asked.
  final String? project;
  final BoardColumn column;
  final List<String> projects;
  final List<SavedServer?> homes;

  @override
  State<_NewCardDialog> createState() => _NewCardDialogState();
}

class _NewCardDialogState extends State<_NewCardDialog> {
  final _title = TextEditingController();
  late final _project = TextEditingController(text: widget.project ?? '');
  late var _column = widget.column;
  late var _server = widget.homes.first;

  @override
  void dispose() {
    _title.dispose();
    _project.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context)
        .pop((title: title, project: _project.text.trim(), column: _column, server: _server));
  }

  @override
  Widget build(BuildContext context) {
    final inLane = widget.project != null;
    return AlertDialog(
      title: Text(
        inLane
            ? 'New card in ${widget.project!.isEmpty ? 'No project' : widget.project} · ${_column.label}'
            : 'New card',
      ),
      // Scrolls when the keyboard leaves too little room (a phone).
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              maxLength: 200,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g. Sweep Fourier modes',
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (!inLane) ...[
              const SizedBox(height: 12),
              ProjectField(controller: _project, projects: widget.projects),
              const SizedBox(height: 16),
              ColumnChoice(value: _column, onChanged: (c) => setState(() => _column = c)),
            ],
            if (widget.homes.length > 1) ...[
              const SizedBox(height: 16),
              DropdownMenu<SavedServer?>(
                initialSelection: _server,
                label: const Text('Saved on'),
                expandedInsets: EdgeInsets.zero,
                onSelected: (server) => setState(() => _server = server),
                dropdownMenuEntries: [
                  for (final server in widget.homes)
                    DropdownMenuEntry(value: server, label: server?.name ?? 'This device'),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: _title,
          builder: (context, _) => FilledButton(
            onPressed: _title.text.trim().isEmpty ? null : _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}

/// A project name, with the board's other projects as chips to pick from.
class ProjectField extends StatelessWidget {
  const ProjectField({
    super.key,
    required this.controller,
    required this.projects,
    this.onSubmitted,
    this.focusNode,
  });

  final TextEditingController controller;
  final List<String> projects;

  /// When the name is entered or picked.
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final text = controller.text.trim().toLowerCase();
        final others = [
          for (final p in projects)
            if (p.isNotEmpty && p.toLowerCase() != text && p.toLowerCase().contains(text)) p,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              focusNode: focusNode,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Project',
                hintText: 'Leave empty for no project',
                counterText: '',
              ),
              onSubmitted: onSubmitted,
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final project in others.take(8))
                    ActionChip(
                      label: Text(project),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        controller.text = project;
                        onSubmitted?.call(project);
                      },
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The four columns as chips.
class ColumnChoice extends StatelessWidget {
  const ColumnChoice({super.key, required this.value, required this.onChanged});

  final BoardColumn value;
  final ValueChanged<BoardColumn> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final column in BoardColumn.values)
          ChoiceChip(
            label: Text(column.label),
            selected: column == value,
            onSelected: (_) => onChanged(column),
          ),
      ],
    );
  }
}

/// What to link a card to: a pooled run or dataset id (see
/// `boardRunsProvider`) and its kind.
typedef PickedLink = ({BoardLinkKind kind, String id});

/// Picks a run, simulation or dataset from every server, leaving out
/// those in [taken] (pooled ids).
Future<PickedLink?> showLinkPicker(BuildContext context, {required Set<String> taken}) =>
    showDialog<PickedLink>(
      context: context,
      builder: (_) => _LinkPicker(taken: taken),
    );

enum _PickKind { runs, simulations, datasets }

class _LinkPicker extends ConsumerStatefulWidget {
  const _LinkPicker({required this.taken});

  final Set<String> taken;

  @override
  ConsumerState<_LinkPicker> createState() => _LinkPickerState();
}

class _LinkPickerState extends ConsumerState<_LinkPicker> {
  var _kind = _PickKind.runs;
  var _query = '';

  bool _matches(List<String> words) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty || words.any((w) => w.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget list;
    if (_kind == _PickKind.datasets) {
      list = AsyncValueView(
        value: ref.watch(boardDatasetsProvider),
        onRetry: () => ref.invalidate(boardDatasetsProvider),
        data: (datasets) => _list([
          for (final Dataset d in datasets)
            if (!widget.taken.contains(d.id) && _matches([d.title, d.host, d.source]))
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: Text(d.title),
                subtitle: d.host.isEmpty ? null : Text(d.host),
                onTap: () => Navigator.of(context).pop((kind: BoardLinkKind.dataset, id: d.id)),
              ),
        ]),
      );
    } else {
      final simulations = _kind == _PickKind.simulations;
      list = AsyncValueView(
        value: ref.watch(boardRunsProvider),
        onRetry: () => ref.invalidate(boardRunsProvider),
        data: (runs) => _list([
          for (final Run run in runs)
            if (run.isSimulation == simulations &&
                !widget.taken.contains(run.id) &&
                _matches([run.name, run.project, run.host, ...run.tags]))
              ListTile(
                leading: Icon(simulations ? Icons.waves_outlined : Icons.show_chart),
                title: Text(run.name),
                subtitle: Text(
                  [
                    if (run.project.isNotEmpty) run.project,
                    run.status.name,
                    if (run.host.isNotEmpty) run.host,
                  ].join(' · '),
                ),
                onTap: () => Navigator.of(context).pop((kind: BoardLinkKind.run, id: run.id)),
              ),
        ]),
      );
    }
    return AlertDialog(
      title: const Text('Link to'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 460,
        // Shorter above a phone's keyboard (the search field has focus).
        height: (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom - 220)
            .clamp(160.0, 460.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Chips, which wrap in a narrow dialog (a phone).
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (kind, label) in const [
                  (_PickKind.runs, 'Runs'),
                  (_PickKind.simulations, 'Simulations'),
                  (_PickKind.datasets, 'Datasets'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() => _kind = kind),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search name, project, host…',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: DefaultTextStyle.merge(style: theme.textTheme.bodyMedium, child: list),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ],
    );
  }

  Widget _list(List<Widget> tiles) {
    if (tiles.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing to link')),
      );
    }
    return ListView(children: tiles);
  }
}
