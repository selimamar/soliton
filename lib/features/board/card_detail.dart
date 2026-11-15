import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/router.dart';
import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/board_providers.dart';
import '../../data/providers.dart';
import '../../data/services/saved_servers.dart';
import '../../models/board_card.dart';
import '../../models/run.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/section_icons.dart';
import 'board_dialogs.dart';
import 'board_screen.dart';

/// An open card: everything on it, editable. Text is saved when its field
/// loses focus (or the card closes); everything else at once.
class CardDetail extends ConsumerStatefulWidget {
  const CardDetail({super.key, required this.cardKey, this.onClosed});

  final String cardKey;
  final VoidCallback? onClosed;

  @override
  ConsumerState<CardDetail> createState() => _CardDetailState();
}

class _CardDetailState extends ConsumerState<CardDetail> {
  final _title = TextEditingController();
  final _project = TextEditingController();
  final _tag = TextEditingController();
  final _notes = TextEditingController();
  final _newItem = TextEditingController();
  final _textFocus = <FocusNode>[];
  late final Board _board;
  PlacedCard? _shown;

  @override
  void initState() {
    super.initState();
    _board = ref.read(boardProvider.notifier);
    final placed = ref.read(boardProvider).value?.byKey(widget.cardKey);
    if (placed != null) _fill(placed.card);
    for (var i = 0; i < 4; i++) {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus) _commitText();
      });
      _textFocus.add(node);
    }
  }

  void _fill(BoardCard card) {
    _title.text = card.title;
    _project.text = card.project;
    _tag.text = card.tag ?? '';
    _notes.text = card.notes;
  }

  @override
  void dispose() {
    _commitText(); // Typed but never left the field.
    for (final node in _textFocus) {
      node.dispose();
    }
    for (final c in [_title, _project, _tag, _notes, _newItem]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Saves the text fields if they changed.
  void _commitText() {
    final placed = _shown;
    if (placed == null) return;
    final card = placed.card;
    final title = _title.text.trim();
    final tag = _tag.text.trim();
    final changed = card.copyWith(
      title: title.isEmpty ? card.title : title,
      project: _project.text.trim(),
      tag: () => tag.isEmpty ? null : tag,
      notes: _notes.text.trim(),
    );
    if (changed.title == card.title &&
        changed.project == card.project &&
        changed.tag == card.tag &&
        changed.notes == card.notes) {
      return;
    }
    // Moving to another project puts it at the end of that lane's column.
    _save(
      placed.withCard(
        changed.project == card.project
            ? changed
            : changed.copyWith(position: _board.endOf(changed.project, changed.column)),
      ),
    );
  }

  Future<void> _save(PlacedCard placed) async {
    _shown = placed;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _board.save(placed);
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text("Couldn't save the card. ${describeError(error).message}")),
      );
    }
  }

  void _change(BoardCard Function(BoardCard card) edit) {
    final placed = _shown;
    if (placed == null) return;
    _save(placed.withCard(edit(placed.card)));
  }

  Future<void> _delete() async {
    final placed = _shown;
    if (placed == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this card?'),
        content: Text('"${placed.card.title}" and its notes go. Linked runs and datasets stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _shown = null;
    widget.onClosed?.call();
    try {
      await _board.delete(placed.key);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't delete the card. ${describeError(error).message}")),
      );
    }
  }

  Future<void> _pickDue() async {
    final placed = _shown;
    if (placed == null) return;
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: placed.card.due ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (day != null) _change((c) => c.copyWith(due: () => day));
  }

  Future<void> _addLink(ServerList servers, Set<String> taken) async {
    final picked = await showLinkPicker(context, taken: taken);
    final placed = _shown;
    if (picked == null || placed == null) return;
    final link = BoardLinks.linkTo(placed, picked.kind, picked.id, servers);
    _change((c) => c.copyWith(links: [...c.links, link]));
  }

  void _addItem() {
    final text = _newItem.text.trim();
    if (text.isEmpty) return;
    _newItem.clear();
    _change(
      (c) => c.copyWith(
        checklist: [
          ...c.checklist,
          ChecklistItem(text: text),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(boardProvider).value;
    final placed = state?.byKey(widget.cardKey);
    if (placed == null) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('This card is gone.')),
      );
    }
    // Someone else's edit (another device): show it, unless typing here.
    if (_shown != null && _shown!.card.updatedAt != placed.card.updatedAt) {
      if (!_textFocus.any((f) => f.hasFocus)) _fill(placed.card);
    }
    _shown = placed;
    final card = placed.card;
    final servers = ref.watch(serversProvider);
    final runs = {
      for (final run in ref.watch(boardRunsProvider).value ?? const <Run>[]) run.id: run,
    };
    final label = theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant);
    final pooledLinks = [for (final link in card.links) BoardLinks.pooledId(placed, link, servers)];
    final tagged = card.tag == null
        ? const <Run>[]
        : [
            for (final run in runs.values)
              if (run.tags.any((t) => t.toLowerCase() == card.tag!.toLowerCase())) run,
          ];

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Text(
        AppText.eyebrowCase(text),
        semanticsLabel: text,
        style: AppText.eyebrow(scheme, color: scheme.onSurfaceVariant),
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _title,
                focusNode: _textFocus[0],
                maxLength: 200,
                maxLines: null,
                style: theme.textTheme.headlineSmall?.copyWith(fontSize: 19),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  counterText: '',
                  hintText: 'Title',
                ),
                onSubmitted: (_) => _commitText(),
              ),
            ),
            if (widget.onClosed != null &&
                MediaQuery.sizeOf(context).width >= BoardScreen.sidePanelWidth)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: widget.onClosed,
              ),
          ],
        ),
        const SizedBox(height: 8),
        ColumnChoice(
          value: card.column,
          onChanged: (column) => _board.move(placed.key, project: card.project, column: column),
        ),
        const SizedBox(height: 12),
        ProjectField(
          controller: _project,
          focusNode: _textFocus[1],
          projects: state!.projects,
          onSubmitted: (_) => _commitText(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (card.due case final due?)
              InputChip(
                avatar: const Icon(Icons.event, size: 18),
                label: Text('Due ${formatShortDate(due)}'),
                onPressed: _pickDue,
                onDeleted: () => _change((c) => c.copyWith(due: () => null)),
                deleteButtonTooltipMessage: 'Remove the due date',
              )
            else
              ActionChip(
                avatar: const Icon(Icons.event, size: 18),
                label: const Text('Add a due date'),
                onPressed: _pickDue,
              ),
          ],
        ),
        heading('Notes'),
        TextField(
          controller: _notes,
          focusNode: _textFocus[3],
          minLines: 3,
          maxLines: 14,
          maxLength: 10000,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'What to try, what you saw, what to do next',
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        heading('Checklist'),
        for (final (i, item) in card.checklist.indexed)
          Row(
            children: [
              Checkbox(
                value: item.done,
                onChanged: (done) => _change(
                  (c) => c.copyWith(
                    checklist: [
                      for (final (j, it) in c.checklist.indexed)
                        j == i ? ChecklistItem(text: it.text, done: done ?? false) : it,
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: item.done ? scheme.onSurfaceVariant : null,
                    decoration: item.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove "${item.text}"',
                visualDensity: VisualDensity.compact,
                onPressed: () => _change(
                  (c) => c.copyWith(
                    checklist: [
                      for (final (j, it) in c.checklist.indexed)
                        if (j != i) it,
                    ],
                  ),
                ),
              ),
            ],
          ),
        TextField(
          controller: _newItem,
          maxLength: 300,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Add a step',
            prefixIcon: const Icon(Icons.add, size: 18),
            isDense: true,
            counterText: '',
            suffixIcon: ListenableBuilder(
              listenable: _newItem,
              builder: (context, _) => _newItem.text.trim().isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Add step',
                      onPressed: _addItem,
                    ),
            ),
          ),
          onSubmitted: (_) => _addItem(),
        ),
        heading('Linked'),
        for (final (i, link) in card.links.indexed)
          _LinkRow(
            link: link,
            pooledId: pooledLinks[i],
            run: pooledLinks[i] == null ? null : runs[pooledLinks[i]],
            onRemove: () => _change(
              (c) => c.copyWith(
                links: [
                  for (final (j, l) in c.links.indexed)
                    if (j != i) l,
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Link a run, simulation or dataset'),
            onPressed: () => _addLink(servers, {for (final id in pooledLinks) ?id}),
          ),
        ),
        heading('Runs by tag'),
        TextField(
          controller: _tag,
          focusNode: _textFocus[2],
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Tag',
            hintText: 'e.g. sweep-modes',
            helperText: 'Runs with this tag belong to the card without linking each one.',
            helperMaxLines: 2,
            counterText: '',
            isDense: true,
          ),
          onSubmitted: (_) => _commitText(),
        ),
        for (final run in tagged)
          _LinkRow(
            link: BoardLink(kind: BoardLinkKind.run, id: run.id),
            pooledId: run.id,
            run: run,
          ),
        const SizedBox(height: 24),
        Text(
          [
            if (placed.server != null && ref.watch(boardPlacesProvider).length > 1)
              'Saved on ${placed.server!.name}',
            if (card.createdAt case final at?) 'added ${formatShortDate(at)}',
            if (card.updatedAt case final at?) 'changed ${formatTimeAgo(at)}',
          ].join(' · '),
          style: label,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete card'),
            onPressed: _delete,
          ),
        ),
      ],
    );
  }
}

/// A linked run, simulation or dataset: tap to open it.
class _LinkRow extends ConsumerWidget {
  const _LinkRow({required this.link, required this.pooledId, required this.run, this.onRemove});

  final BoardLink link;

  /// Null when it is on a server this device doesn't know.
  final String? pooledId;
  final Run? run;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dataset = link.kind == BoardLinkKind.dataset;
    final run = this.run;
    final status = dataset
        ? 'dataset'
        : run == null
        ? (pooledId == null ? 'on a server not added here' : 'not found')
        : [
            run.status.label,
            if (run.status == RunStatus.live && run.progress > 0) formatPercent(run.progress),
          ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: run != null
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: run.status.color(scheme), shape: BoxShape.circle),
            )
          : dataset
          ? const Icon(Icons.storage_outlined, size: 18)
          : const SectionIcon.runs(size: 18),
      minLeadingWidth: 18,
      title: Text(run?.name ?? link.id, style: AppText.mono(context)),
      subtitle: Text(status),
      onTap: pooledId == null || (!dataset && run == null)
          ? null
          : () => openPooled(context, ref, pooledId!, dataset: dataset),
      trailing: onRemove == null
          ? null
          : IconButton(
              icon: const Icon(Icons.link_off, size: 18),
              tooltip: 'Unlink ${run?.name ?? link.id}',
              onPressed: onRemove,
            ),
    );
  }
}

/// Opens a run's or dataset's page from its pooled id. If the runs list
/// shows another server, it switches to the one this is on first.
/// Back returns to the board.
void openPooled(BuildContext context, WidgetRef ref, String pooledId, {bool dataset = false}) {
  // Not through [context]: switching servers reloads the board under it.
  final router = ref.read(routerProvider);
  final messenger = ScaffoldMessenger.of(context);
  final servers = ref.read(serversProvider);
  final (serverId, localId) = BoardLinks.split(pooledId);
  String route(String id) => dataset ? AppRoutes.dataset(id) : AppRoutes.run(id);
  if (serverId == null || servers.showsAll) {
    router.push(route(pooledId));
    return;
  }
  if (servers.currentId != serverId) {
    ref.read(serversProvider.notifier).switchTo(serverId);
    final name = servers.servers.where((s) => s.id == serverId).firstOrNull?.name;
    if (name != null) {
      messenger.showSnackBar(SnackBar(content: Text('Now showing $name')));
    }
  }
  router.push(route(localId));
}
