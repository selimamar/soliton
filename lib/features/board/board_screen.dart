import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/board_providers.dart';
import '../../data/providers.dart';
import '../../data/services/saved_servers.dart';
import '../../models/board_card.dart';
import '../../models/run.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/connection_banner.dart';
import 'board_dialogs.dart';
import 'card_detail.dart';

/// The Board section: to-do cards in lanes, one per project, across Ideas,
/// To do, Running and Done. Cards link to runs, simulations and datasets
/// and show how those are doing. Every server's cards are on this one
/// board; each card is saved on one of them.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key});

  /// Wide enough to show the open card beside the board.
  static const sidePanelWidth = 1100.0;

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  /// The open card's key, on wide screens (narrow ones open a page).
  String? _open;

  void _openCard(String key) {
    if (MediaQuery.sizeOf(context).width >= BoardScreen.sidePanelWidth) {
      setState(() => _open = _open == key ? null : key);
      return;
    }
    // Over the section bar too, like a run's page.
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (page) => Scaffold(
          appBar: AppBar(title: const Text('Card')),
          body: CardDetail(cardKey: key, onClosed: () => Navigator.of(page).maybePop()),
        ),
      ),
    );
  }

  Future<void> _newCard({String? project, BoardColumn column = BoardColumn.todo}) async {
    final key = await showNewCardDialog(context, ref, project: project, column: column);
    if (key != null && mounted) _openCard(key);
  }

  @override
  Widget build(BuildContext context) {
    final hideDone = ref.watch(boardHideDoneProvider);
    final wide = MediaQuery.sizeOf(context).width >= BoardScreen.sidePanelWidth;
    final board = ref.watch(boardProvider);
    final open = _open != null && board.value?.byKey(_open!) != null ? _open : null;
    final canAdd = ref.watch(boardPlacesProvider).isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Image.asset('assets/branding/app_mark.png', width: 24, height: 24),
            ),
            const SizedBox(width: 10),
            const Flexible(child: Text('Board', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(hideDone ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            tooltip: hideDone ? 'Show done' : 'Hide done',
            onPressed: () => ref.read(boardHideDoneProvider.notifier).set(!hideDone),
          ),
          if (canAdd)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New card',
              onPressed: () => _newCard(),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.go(AppRoutes.settings),
          ),
        ],
      ),
      body: AsyncValueView(
        value: board,
        onRetry: () => ref.invalidate(boardProvider),
        data: (state) {
          final view = _BoardView(
            state: state,
            open: open,
            hideDone: hideDone,
            onOpen: _openCard,
            onAdd: (project, column) => _newCard(project: project, column: column),
          );
          if (!wide || open == null) return view;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: view),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                ),
                child: SizedBox(
                  width: 400,
                  child: CardDetail(
                    key: ValueKey(open),
                    cardKey: open,
                    onClosed: () => setState(() => _open = null),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BoardView extends ConsumerWidget {
  const _BoardView({
    required this.state,
    required this.open,
    required this.hideDone,
    required this.onOpen,
    required this.onAdd,
  });

  final BoardState state;
  final String? open;
  final bool hideDone;
  final void Function(String key) onOpen;
  final void Function(String project, BoardColumn column) onAdd;

  /// Narrower than this, columns scroll sideways instead of shrinking.
  static const minColumnWidth = 230.0;

  /// Narrower than this (a phone), one column is shown at a time, picked
  /// with tabs above the lanes.
  static const phoneWidth = 600.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final columns = [
      for (final column in BoardColumn.values)
        if (!(hideDone && column == BoardColumn.done)) column,
    ];
    final runs = {
      for (final run in ref.watch(boardRunsProvider).value ?? const <Run>[]) run.id: run,
    };
    final collapsed = ref.watch(boardCollapsedProvider);
    final canAdd = ref.watch(boardPlacesProvider).isNotEmpty;
    final projects = state.projects;

    final notices = [
      const ConnectionBanner(),
      if (state.outdated.isNotEmpty)
        _Notice(
          '${_names(state.outdated)} ${state.outdated.length == 1 ? 'is' : 'are'} too old to keep '
          'a board: update soliton-server there to see and add cards on it.',
        ),
      if (state.unreachable.isNotEmpty)
        _Notice("Couldn't reach ${_names(state.unreachable)}: its cards aren't shown."),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        const padding = 12.0;
        if (constraints.maxWidth < phoneWidth) {
          var shown = ref.watch(boardPhoneColumnProvider);
          if (!columns.contains(shown)) shown = BoardColumn.todo;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(boardProvider.future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(padding, 8, padding, 48),
              children: [
                ...notices,
                if (projects.isEmpty)
                  _Empty(canAdd: canAdd, onAdd: () => onAdd('', BoardColumn.todo))
                else ...[
                  _ColumnTabs(columns: columns, shown: shown, state: state),
                  for (final project in projects)
                    _Lane(
                      project: project,
                      columns: [shown],
                      state: state,
                      runs: runs,
                      open: open,
                      collapsed: collapsed.contains(project),
                      onOpen: onOpen,
                      onAdd: onAdd,
                    ),
                ],
              ],
            ),
          );
        }
        final fits = constraints.maxWidth - 2 * padding >= columns.length * (minColumnWidth + gap);
        final width = fits
            ? constraints.maxWidth
            : 2 * padding + columns.length * (minColumnWidth + gap);

        Widget header() => Row(
          children: [
            for (final column in columns)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: gap / 2 + 4, vertical: 4),
                  child: Text(
                    AppText.eyebrowCase(column.label),
                    semanticsLabel: column.label,
                    style: AppText.eyebrow(
                      theme.colorScheme,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        );

        final board = RefreshIndicator(
          onRefresh: () => ref.refresh(boardProvider.future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(padding, 8, padding, 48),
            children: [
              ...notices,
              if (projects.isEmpty)
                _Empty(canAdd: canAdd, onAdd: () => onAdd('', BoardColumn.todo))
              else ...[
                header(),
                for (final project in projects)
                  _Lane(
                    project: project,
                    columns: columns,
                    state: state,
                    runs: runs,
                    open: open,
                    collapsed: collapsed.contains(project),
                    onOpen: onOpen,
                    onAdd: onAdd,
                  ),
              ],
            ],
          ),
        );
        if (fits) return board;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width, height: constraints.maxHeight, child: board),
        );
      },
    );
  }

  static String _names(List<String> names) => names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// On a phone, the column the board shows.
final boardPhoneColumnProvider = NotifierProvider<_PhoneColumn, BoardColumn>(_PhoneColumn.new);

class _PhoneColumn extends Notifier<BoardColumn> {
  @override
  BoardColumn build() => BoardColumn.todo;

  void show(BoardColumn column) => state = column;
}

/// On a phone: a tab per column, with its number of cards. Drop a card on
/// a tab to move it to that column (in its own project).
class _ColumnTabs extends ConsumerWidget {
  const _ColumnTabs({required this.columns, required this.shown, required this.state});

  final List<BoardColumn> columns;
  final BoardColumn shown;
  final BoardState state;

  Future<void> _move(BuildContext context, WidgetRef ref, String key, BoardColumn column) async {
    final messenger = ScaffoldMessenger.of(context);
    final placed = state.byKey(key);
    if (placed == null) return;
    try {
      await ref
          .read(boardProvider.notifier)
          .move(key, project: placed.card.project, column: column);
      messenger.showSnackBar(
        SnackBar(content: Text('Moved "${placed.card.title}" to ${column.label}')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't move the card. ${describeError(error).message}")),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final radius = AppTheme.radiusOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        children: [
          for (final column in columns)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      state.byKey(details.data)?.card.column != column,
                  onAcceptWithDetails: (details) => _move(context, ref, details.data, column),
                  builder: (context, candidates, _) {
                    final selected = column == shown;
                    final dropping = candidates.isNotEmpty;
                    final count = state.cards.where((c) => c.card.column == column).length;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: '${column.label}, $count ${count == 1 ? 'card' : 'cards'}',
                      excludeSemantics: true,
                      child: Material(
                        color: dropping
                            ? scheme.primaryContainer
                            : selected
                            ? scheme.surfaceContainerLowest
                            : scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(radius + 2),
                          side: BorderSide(
                            color: selected || dropping ? scheme.primary : scheme.outlineVariant,
                            width: selected ? 1.5 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(radius + 2),
                          onTap: () => ref.read(boardPhoneColumnProvider.notifier).show(column),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              children: [
                                Text(
                                  AppText.eyebrowCase(column.label),
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  style: AppText.eyebrow(
                                    scheme,
                                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                                  ).copyWith(letterSpacing: 0.6),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$count',
                                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.canAdd, required this.onAdd});

  final bool canAdd;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Text(
            canAdd
                ? 'Keep track of what to try next: a card per idea or task, in a lane per '
                      'project, linked to the runs, simulations and datasets it is about.'
                : 'Connect a server to keep a board. Its cards are saved there, so every '
                      'device sees them.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (canAdd) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New card'),
              onPressed: onAdd,
            ),
          ],
        ],
      ),
    );
  }
}

/// One project's row: its name, then a cell per column.
class _Lane extends ConsumerWidget {
  const _Lane({
    required this.project,
    required this.columns,
    required this.state,
    required this.runs,
    required this.open,
    required this.collapsed,
    required this.onOpen,
    required this.onAdd,
  });

  final String project;
  final List<BoardColumn> columns;
  final BoardState state;
  final Map<String, Run> runs;
  final String? open;
  final bool collapsed;
  final void Function(String key) onOpen;
  final void Function(String project, BoardColumn column) onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final servers = ref.watch(serversProvider);
    final cards = [
      for (final c in state.cards)
        if (c.card.project == project) c,
    ];
    final live = {
      for (final placed in cards)
        for (final run in cardRuns(placed, runs, servers))
          if (run.status == RunStatus.live) run.id,
    }.length;
    final name = project.isEmpty ? 'No project' : project;
    final summary = [
      '${cards.length} ${cards.length == 1 ? 'card' : 'cards'}',
      if (live > 0) '$live live',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: !collapsed,
          label: '$name, $summary',
          excludeSemantics: true,
          child: InkWell(
            onTap: () => ref.read(boardCollapsedProvider.notifier).toggle(project),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
              // Not Flexible: that would split the room with the rule. Shares
              // of the width instead, so a long name shortens on a phone.
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(420, constraints.maxWidth * 0.55),
                      ),
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontSize: 17,
                          color: project.isEmpty ? theme.colorScheme.onSurfaceVariant : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.3),
                      child: Text(
                        summary,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Divider(color: theme.colorScheme.outlineVariant, height: 1)),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!collapsed)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final column in columns)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _Cell(
                        project: project,
                        column: column,
                        cards: state.cell(project, column),
                        runs: runs,
                        open: open,
                        onOpen: onOpen,
                        onAdd: () => onAdd(project, column),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One project's cards in one column; cards dropped here move here.
class _Cell extends ConsumerStatefulWidget {
  const _Cell({
    required this.project,
    required this.column,
    required this.cards,
    required this.runs,
    required this.open,
    required this.onOpen,
    required this.onAdd,
  });

  final String project;
  final BoardColumn column;
  final List<PlacedCard> cards;
  final Map<String, Run> runs;
  final String? open;
  final void Function(String key) onOpen;
  final VoidCallback onAdd;

  @override
  ConsumerState<_Cell> createState() => _CellState();
}

class _CellState extends ConsumerState<_Cell> {
  /// Done cells show only their latest card until opened up.
  var _showAll = false;

  Future<void> _move(String key) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(boardProvider.notifier)
          .move(key, project: widget.project, column: widget.column);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't move the card. ${describeError(error).message}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = AppTheme.radiusOf(context);
    final done = widget.column == BoardColumn.done;
    var cards = widget.cards;
    var hidden = 0;
    if (done && !_showAll && cards.length > 1) {
      // The most recently finished one.
      final latest = [...cards]
        ..sort(
          (a, b) => (b.card.updatedAt ?? DateTime(0)).compareTo(a.card.updatedAt ?? DateTime(0)),
        );
      hidden = cards.length - 1;
      cards = [latest.first];
    }
    final canAdd = ref.watch(boardPlacesProvider).isNotEmpty;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => !widget.cards.any((c) => c.key == details.data),
      onAcceptWithDetails: (details) => _move(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          border: Border.all(
            color: candidates.isNotEmpty
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(radius + 2),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final placed in cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: BoardCardTile(
                    placed: placed,
                    runs: widget.runs,
                    selected: widget.open == placed.key,
                    onTap: () => widget.onOpen(placed.key),
                  ),
                ),
              if (hidden > 0 || (done && _showAll && widget.cards.length > 1))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: _smallButton,
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(_showAll ? 'Show fewer' : '+ $hidden more'),
                  ),
                ),
              if (canAdd)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: _smallButton,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add'),
                    onPressed: widget.onAdd,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static final _smallButton = TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    textStyle: const TextStyle(fontSize: 12),
  );
}

/// The runs a card is about: those it links, and those with its tag.
List<Run> cardRuns(PlacedCard placed, Map<String, Run> runs, ServerList servers) {
  final found = <String, Run>{};
  for (final link in placed.card.links) {
    if (link.kind != BoardLinkKind.run) continue;
    final run = switch (BoardLinks.pooledId(placed, link, servers)) {
      final id? => runs[id],
      null => null,
    };
    if (run != null) found[run.id] = run;
  }
  if (placed.card.tag case final tag?) {
    final wanted = tag.toLowerCase();
    for (final run in runs.values) {
      if (run.tags.any((t) => t.toLowerCase() == wanted)) found[run.id] = run;
    }
  }
  return found.values.toList();
}

/// A card on the board: its title, what it links to and how that is doing,
/// its checklist and due date. Drag it to another column or project.
class BoardCardTile extends ConsumerWidget {
  const BoardCardTile({
    super.key,
    required this.placed,
    required this.runs,
    required this.selected,
    required this.onTap,
  });

  final PlacedCard placed;
  final Map<String, Run> runs;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tile = _tile(context, ref);
    final feedback = Material(
      color: Colors.transparent,
      child: SizedBox(width: 220, child: Opacity(opacity: 0.9, child: tile)),
    );
    final touch =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    return touch
        ? LongPressDraggable<String>(
            data: placed.key,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: 0.35, child: tile),
            child: tile,
          )
        : Draggable<String>(
            data: placed.key,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: 0.35, child: tile),
            child: tile,
          );
  }

  Widget _tile(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = AppTheme.radiusOf(context);
    final servers = ref.watch(serversProvider);
    final card = placed.card;
    final done = card.column == BoardColumn.done;

    final chips = <Widget>[];
    for (final link in card.links) {
      final id = BoardLinks.pooledId(placed, link, servers);
      final run = id == null ? null : runs[id];
      chips.add(
        LinkChip(
          icon: link.kind == BoardLinkKind.dataset
              ? Icons.storage_outlined
              : run?.isSimulation ?? false
              ? Icons.waves_outlined
              : Icons.show_chart,
          label: run?.name ?? link.id,
          status: link.kind == BoardLinkKind.run ? run?.status : null,
          trailing: run != null && run.status == RunStatus.live && run.progress > 0
              ? formatPercent(run.progress).replaceFirst('.0%', '%')
              : null,
        ),
      );
    }
    if (card.tag case final tag?) {
      final tagged = [
        for (final run in runs.values)
          if (run.tags.any((t) => t.toLowerCase() == tag.toLowerCase())) run,
      ];
      final live = tagged.where((r) => r.status == RunStatus.live).length;
      final crashed = tagged.where((r) => r.status == RunStatus.crashed).length;
      chips.add(
        LinkChip(
          icon: Icons.sell_outlined,
          label: [
            tag,
            '${tagged.length} ${tagged.length == 1 ? 'run' : 'runs'}',
            if (live > 0) '$live live',
            if (crashed > 0) '$crashed crashed',
          ].join(' · '),
          status: crashed > 0
              ? RunStatus.crashed
              : live > 0
              ? RunStatus.live
              : null,
        ),
      );
    }

    final meta = [
      if (card.checklist.isNotEmpty) '${card.checked}/${card.checklist.length}',
      if (card.due case final due?) 'due ${formatShortDate(due)}',
      if (ref.watch(boardPlacesProvider).length > 1 && placed.server != null) placed.server!.name,
    ];
    final overdue = card.due != null && !done && card.due!.isBefore(_today());

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                card.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: done ? scheme.onSurfaceVariant : null,
                  height: 1.3,
                ),
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 4, runSpacing: 4, children: chips),
              ],
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (card.checklist.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Icon(
                          Icons.check_box_outlined,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                          semanticLabel: 'Checklist',
                        ),
                      ),
                    Flexible(
                      child: Text(
                        meta.join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: overdue ? scheme.error : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}

/// A small label for something a card links to, with its status's colour.
class LinkChip extends StatelessWidget {
  const LinkChip({super.key, required this.icon, required this.label, this.status, this.trailing});

  final IconData icon;
  final String label;
  final RunStatus? status;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = AppText.mono(context).copyWith(fontSize: 11, color: scheme.onSurfaceVariant);
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status case final status?)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(color: status.color(scheme), shape: BoxShape.circle),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(icon, size: 12, color: scheme.onSurfaceVariant),
            ),
          Flexible(
            child: Text(label, style: mono, overflow: TextOverflow.ellipsis),
          ),
          if (trailing case final trailing?) Text(' · $trailing', style: mono),
        ],
      ),
    );
  }
}
