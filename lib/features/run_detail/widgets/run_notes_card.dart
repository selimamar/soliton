import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/providers.dart';
import '../../../data/tags.dart';
import '../../../models/run.dart';
import '../../../shared/widgets/async_value_view.dart';
import '../../../shared/widgets/section_card.dart';

/// A run's tags (to group runs by) and its note, editable. Saved on the
/// server, so every device sees them.
class RunNotesCard extends ConsumerWidget {
  const RunNotesCard({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notes = run.notes.trim();

    return SectionCard(
      title: 'Tags and notes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in run.tags)
                InputChip(
                  label: Text(tag),
                  onDeleted: () => _saveTags(context, ref, [...run.tags]..remove(tag)),
                  deleteButtonTooltipMessage: 'Remove tag $tag',
                ),
              if (run.tags.length < maxTags)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add tag'),
                  onPressed: () => _addTag(context, ref),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (notes.isEmpty)
            Text(
              'No note yet: write down what you tried, or what you noticed.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            SelectableText(notes, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          TextButton.icon(
            icon: const Icon(Icons.edit_note),
            label: Text(notes.isEmpty ? 'Add a note' : 'Edit note'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _NoteDialog(
                initial: run.notes,
                save: (text) => ref.read(runNotesEditorProvider).save(run.id, notes: text),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addTag(BuildContext context, WidgetRef ref) async {
    final tag = await showDialog<String>(
      context: context,
      builder: (_) => _TagDialog(taken: {for (final tag in run.tags) tag.toLowerCase()}),
    );
    if (tag == null || !context.mounted) return;
    await _saveTags(context, ref, [...run.tags, tag]);
  }

  Future<void> _saveTags(BuildContext context, WidgetRef ref, List<String> tags) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(runNotesEditorProvider).save(run.id, tags: cleanTags(tags));
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't save the tags. ${describeError(error).message}")),
      );
    }
  }
}

/// Asks for a tag, suggesting those of other runs.
class _TagDialog extends ConsumerStatefulWidget {
  const _TagDialog({required this.taken});

  /// This run's tags, in lower case: not suggested.
  final Set<String> taken;

  @override
  ConsumerState<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends ConsumerState<_TagDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    final tag = (value ?? _text.text).trim();
    if (tag.isNotEmpty) Navigator.of(context).pop(tag);
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = [
      for (final tag in cleanTags([
        for (final run in ref.watch(runsProvider).value ?? const <Run>[]) ...run.tags,
      ]))
        if (!widget.taken.contains(tag.toLowerCase())) tag,
    ];
    return AlertDialog(
      title: const Text('Add a tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: maxTagLength,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Tag',
              hintText: 'e.g. baseline, ablation, best',
            ),
            onSubmitted: _submit,
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Used on other runs', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in suggestions)
                  ActionChip(label: Text(tag), onPressed: () => _submit(tag)),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: _text,
          builder: (context, _) => FilledButton(
            onPressed: _text.text.trim().isEmpty ? null : _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}

/// Edits a note; stays open (keeping the text) if saving fails.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial, required this.save});

  final String initial;
  final Future<void> Function(String text) save;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _text = TextEditingController(text: widget.initial);
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_text.text.trim());
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save. ${describeError(error).message}";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Note'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _text,
          autofocus: true,
          minLines: 5,
          maxLines: 12,
          maxLength: maxNotesLength,
          enabled: !_saving,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            hintText: 'What you tried, what you saw, what to try next',
            border: const OutlineInputBorder(),
            errorText: _error,
            errorMaxLines: 3,
            counterText: '',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
      ],
    );
  }
}
