import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/theme.dart';

/// What a list is searched for (empty: everything), until the app restarts.
class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// The runs list's search.
final runSearchProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

/// Compute's search.
final simulationSearchProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

/// Data's search.
final datasetSearchProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

/// Whether every word of [query] is in one of [fields], ignoring case:
/// "fno sherlock" finds the FNO runs on Sherlock. An empty query matches.
bool matchesSearch(String query, Iterable<String?> fields) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final text = [
    for (final f in fields)
      if (f != null && f.isNotEmpty) f.toLowerCase(),
  ];
  return words.every((word) => text.any((f) => f.contains(word)));
}

/// The search box at the top of a list: a magnifier, the query, and a
/// button to clear it. Kept in [provider], so it survives leaving the list.
class ListSearchField extends ConsumerStatefulWidget {
  const ListSearchField({super.key, required this.provider, required this.hint});

  final NotifierProvider<SearchQuery, String> provider;

  /// E.g. "Search by name, tag, project or host".
  final String hint;

  @override
  ConsumerState<ListSearchField> createState() => _ListSearchFieldState();
}

class _ListSearchFieldState extends ConsumerState<ListSearchField> {
  late final _text = TextEditingController(text: ref.read(widget.provider));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(String query) => ref.read(widget.provider.notifier).set(query);

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(widget.provider);
    if (query != _text.text) _text.text = query;
    final scheme = Theme.of(context).colorScheme;
    final journal = AppTheme.styleOf(context) == AppStyle.ink;
    final radius = BorderRadius.circular(AppTheme.radiusOf(context));
    InputBorder border(Color color) => journal
        ? UnderlineInputBorder(borderSide: BorderSide(color: color))
        : OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: color),
          );
    return TextField(
      controller: _text,
      onChanged: _set,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Clear search',
                onPressed: () {
                  _text.clear();
                  _set('');
                },
              ),
        filled: !journal,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        enabledBorder: border(scheme.outlineVariant),
        focusedBorder: border(scheme.primary),
      ),
    );
  }
}
