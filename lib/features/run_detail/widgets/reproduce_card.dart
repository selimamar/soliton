import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/system_info.dart';
import '../../../shared/widgets/key_value_row.dart';
import '../../../shared/widgets/section_card.dart';

/// System tab: what it takes to run this again, as the logger recorded it:
/// the code's commit (and uncommitted files), the command and where it ran,
/// the Slurm job script and the Python packages, with buttons to copy the
/// command and read the script and packages.
class ReproduceCard extends StatelessWidget {
  const ReproduceCard({super.key, required this.repro});

  final ReproInfo repro;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final mono = AppText.mono(context).copyWith(fontSize: 12);
    final rerun = repro.rerun;
    return SectionCard(
      title: 'Reproduce',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (repro.commit case final commit?) ...[
            KeyValueRow(
              label: 'Code',
              value: [
                commit.length > 7 ? commit.substring(0, 7) : commit,
                ?repro.branch,
              ].join(' on '),
            ),
            if (repro.remote case final remote?) Text(remote, style: muted),
            if (repro.changedFiles > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Uncommitted changes in ${repro.changedFiles == 1 ? '1 file' : '${repro.changedFiles} files'}'
                  ': ${repro.dirty.take(5).join(', ')}${repro.changedFiles > 5 ? ', …' : ''}. '
                  'This commit alone may not give the same result.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (repro.cwd case final cwd?) KeyValueRow(label: 'Directory', value: cwd),
          if (repro.command case final command?) ...[
            const SizedBox(height: 4),
            Text('Command', style: muted),
            const SizedBox(height: 2),
            SelectableText(command, style: mono),
            if (rerun == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Not offered to copy: it has shell operators (such as ; | \$( ) the logger never '
                  'writes, so it may not be what the run ran. Read it before running any of it.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (rerun != null)
                TextButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('Copy command to rerun'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: rerun));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(content: Text('Copied the command')));
                  },
                ),
              if (repro.jobScript case final script?)
                TextButton.icon(
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('Job script'),
                  onPressed: () => _showText(context, 'Job script', script),
                ),
              if (repro.packages.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.inventory_2_outlined, size: 16),
                  label: Text('${repro.packages.length} packages'),
                  onPressed: () => _showText(context, 'Python packages', repro.packages.join('\n')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// [text] full screen, selectable, with a button to copy it all.
Future<void> _showText(BuildContext context, String title, String text) => showDialog<void>(
  context: context,
  builder: (context) => Dialog.fullscreen(
    child: ScaffoldMessenger(
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(title),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: 'Copy all',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Copied')));
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(text, style: AppText.mono(context).copyWith(fontSize: 12)),
          ),
        ),
      ),
    ),
  ),
);
