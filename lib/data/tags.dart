/// Tags as the server keeps them: trimmed, 1 to [maxTagLength] characters,
/// each once (ignoring case), at most [maxTags].
library;

const maxTagLength = 40;
const maxTags = 20;
const maxNotesLength = 10000;

List<String> cleanTags(Iterable<String> tags) {
  final kept = <String>[];
  final seen = <String>{};
  for (final tag in tags) {
    final text = tag.trim();
    if (text.isEmpty || text.length > maxTagLength) continue;
    if (seen.add(text.toLowerCase())) kept.add(text);
  }
  return kept.take(maxTags).toList();
}
