/// The board's columns, left to right.
enum BoardColumn {
  ideas('Ideas'),
  todo('To do'),
  running('Running'),
  done('Done');

  const BoardColumn(this.label);

  final String label;

  /// The server's name for it.
  String get key => name;

  static BoardColumn parse(Object? value) => values.asNameMap()[value] ?? BoardColumn.todo;
}

/// One line of a card's checklist.
class ChecklistItem {
  const ChecklistItem({required this.text, this.done = false});

  factory ChecklistItem.fromJson(Map<String, Object?> json) =>
      ChecklistItem(text: json['text'] as String? ?? '', done: json['done'] == true);

  final String text;
  final bool done;

  Map<String, Object?> toJson() => {'text': text, 'done': done};

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem && other.text == text && other.done == done;

  @override
  int get hashCode => Object.hash(text, done);
}

enum BoardLinkKind { run, dataset }

/// What a card points at: a run (or simulation) or a dataset, by its id on
/// a server. [server] is the address of that server, or empty for the
/// server the card itself is saved on (always empty on demo data).
class BoardLink {
  const BoardLink({required this.kind, required this.id, this.server = ''});

  factory BoardLink.fromJson(Map<String, Object?> json) => BoardLink(
    kind: json['kind'] == 'dataset' ? BoardLinkKind.dataset : BoardLinkKind.run,
    id: json['id'] as String? ?? '',
    server: json['server'] as String? ?? '',
  );

  final BoardLinkKind kind;
  final String id;
  final String server;

  Map<String, Object?> toJson() => {'kind': kind.name, 'id': id, 'server': server};

  @override
  bool operator ==(Object other) =>
      other is BoardLink && other.kind == kind && other.id == id && other.server == server;

  @override
  int get hashCode => Object.hash(kind, id, server);
}

/// A card on the to-do board, as one server keeps it. [id] is its id on
/// that server.
class BoardCard {
  const BoardCard({
    required this.id,
    required this.title,
    this.project = '',
    this.column = BoardColumn.todo,
    this.position = 0,
    this.notes = '',
    this.checklist = const [],
    this.links = const [],
    this.tag,
    this.due,
    this.createdAt,
    this.updatedAt,
  });

  factory BoardCard.fromJson(Map<String, Object?> json) => BoardCard(
    id: json['id']! as String,
    title: json['title'] as String? ?? '',
    project: json['project'] as String? ?? '',
    column: BoardColumn.parse(json['column']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    notes: json['notes'] as String? ?? '',
    checklist: List.unmodifiable([
      for (final item in json['checklist'] as List? ?? const [])
        if (item is Map<String, Object?>) ChecklistItem.fromJson(item),
    ]),
    links: List.unmodifiable([
      for (final link in json['links'] as List? ?? const [])
        if (link is Map<String, Object?>) BoardLink.fromJson(link),
    ]),
    tag: switch (json['tag']) {
      final String tag when tag.isNotEmpty => tag,
      _ => null,
    },
    due: _day(json['due']),
    createdAt: _time(json['createdAt']),
    updatedAt: _time(json['updatedAt']),
  );

  final String id;
  final String title;

  /// Its lane on the board; empty: "No project".
  final String project;
  final BoardColumn column;

  /// Order within its project and column, smallest first.
  final double position;
  final String notes;
  final List<ChecklistItem> checklist;
  final List<BoardLink> links;

  /// Runs with this tag belong to the card without being linked one by one.
  final String? tag;

  /// A day (its time is midnight, local).
  final DateTime? due;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  int get checked => checklist.where((item) => item.done).length;

  /// What the server stores (it sets the times itself).
  Map<String, Object?> toJson() => {
    'title': title,
    'project': project,
    'column': column.key,
    'position': position,
    'notes': notes,
    'checklist': [for (final item in checklist) item.toJson()],
    'links': [for (final link in links) link.toJson()],
    'tag': tag,
    'due': due == null ? null : formatDay(due!),
  };

  BoardCard copyWith({
    String? title,
    String? project,
    BoardColumn? column,
    double? position,
    String? notes,
    List<ChecklistItem>? checklist,
    List<BoardLink>? links,
    String? Function()? tag,
    DateTime? Function()? due,
  }) => BoardCard(
    id: id,
    title: title ?? this.title,
    project: project ?? this.project,
    column: column ?? this.column,
    position: position ?? this.position,
    notes: notes ?? this.notes,
    checklist: List.unmodifiable(checklist ?? this.checklist),
    links: List.unmodifiable(links ?? this.links),
    tag: tag == null ? this.tag : tag(),
    due: due == null ? this.due : due(),
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  /// "2026-11-18".
  static String formatDay(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static DateTime? _day(Object? value) {
    if (value is! String) return null;
    final parts = value.split('-');
    if (parts.length != 3) return null;
    final [year, month, day] = [for (final p in parts) int.tryParse(p)];
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}
