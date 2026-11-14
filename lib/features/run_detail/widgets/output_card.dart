import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../data/providers.dart';
import '../../../data/services/settings_store.dart';
import '../../../models/run.dart';
import '../../../models/run_output.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';

/// Whether a crashed run's Overview shows its output (the traceback) or
/// just the card's title, to open it. Hidden until shown; saved, for every
/// crashed run.
final showCrashOutputProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('showCrashOutput', false),
);

/// The end of what a run's script printed: for a crashed run, the
/// traceback. Opens the whole output kept on the server. Nothing when the
/// run printed nothing (or its logger doesn't send its output).
class OutputCard extends ConsumerWidget {
  const OutputCard({super.key, required this.run});

  final Run run;

  /// Lines shown on the card; a traceback needs a few more.
  static const _shown = 8, _shownCrashed = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(runOutputProvider(run.id)).value;
    if (output == null || output.lines.isEmpty) return const SizedBox.shrink();
    final crashed = run.status == RunStatus.crashed;
    final count = crashed ? _shownCrashed : _shown;
    final tail = output.lines.length > count
        ? output.lines.sublist(output.lines.length - count)
        : output.lines;
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final lineCount = Text(
      output.total == 1 ? '1 line' : '${formatInt(output.total)} lines',
      style: muted,
    );
    // A crashed run's output can be put away; the banner above still says
    // what went wrong.
    final shown = !crashed || ref.watch(showCrashOutputProvider);
    final trailing = !crashed
        ? lineCount
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              lineCount,
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(shown ? Icons.expand_less : Icons.expand_more),
                tooltip: shown ? 'Hide output' : 'Show output',
                onPressed: () => ref.read(showCrashOutputProvider.notifier).set(!shown),
              ),
            ],
          );
    if (!shown) {
      return SectionCard(
        title: 'Output',
        trailing: trailing,
        child: Text('Hidden on crashed runs: the arrow shows it.', style: muted),
      );
    }
    return SectionCard(
      title: 'Output',
      trailing: trailing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Lines(lines: tail, errorAtEnd: crashed),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            // In the text colour: the accent is too faint on a card in the dark.
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
              icon: const Icon(Icons.open_in_full, size: 16),
              onPressed: () => showOutput(context, run: run, output: output),
              label: Text(output.lines.length > tail.length ? 'Show all output' : 'Open to copy'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lines in monospace, wrapped; the last one in the error colour when the
/// run crashed (it's the error).
class _Lines extends StatelessWidget {
  const _Lines({required this.lines, required this.errorAtEnd, this.selectable = false});

  final List<String> lines;
  final bool errorAtEnd;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = AppText.mono(context).copyWith(fontSize: 12);
    final span = TextSpan(
      style: mono,
      children: [
        for (final (i, line) in lines.indexed)
          TextSpan(
            text: i == lines.length - 1 ? line : '$line\n',
            style: errorAtEnd && i == lines.length - 1
                ? TextStyle(color: scheme.error, fontWeight: FontWeight.w600)
                : null,
          ),
      ],
    );
    return selectable ? SelectableText.rich(span) : Text.rich(span);
  }
}

/// The whole output kept on the server, full screen, starting at the end;
/// selectable, with a button to copy all of it.
Future<void> showOutput(BuildContext context, {required Run run, required RunOutput output}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      // Its own messenger: "Copied" shows here, not also on the page below.
      child: ScaffoldMessenger(
        child: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
              ),
              title: Text('Output · ${run.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Copy all',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: output.lines.join('\n')));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(content: Text('Copied ${formatInt(output.lines.length)} lines')),
                      );
                  },
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: SingleChildScrollView(
              // Starts at the end, where the error is.
              reverse: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (output.dropped > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'The first ${formatInt(output.dropped)} lines are not kept: these are the '
                        'last ${formatInt(output.lines.length)}.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  _Lines(
                    lines: output.lines,
                    errorAtEnd: run.status == RunStatus.crashed,
                    selectable: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
