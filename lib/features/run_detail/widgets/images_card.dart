import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/providers.dart';
import '../../../models/logged_image.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';

/// The pictures a run logged (`run.log_image`), one card each, with a
/// slider over the steps it was logged at. Nothing for a run without any.
/// Tapping a picture opens it large, to zoom in.
class ImagesCards extends ConsumerWidget {
  const ImagesCards({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(imagesProvider(runId)).value ?? const <ImageSeries>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, series) in images.where((s) => s.steps.isNotEmpty).indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          _ImageCard(key: ValueKey(series.name), runId: runId, series: series),
        ],
      ],
    );
  }
}

/// The most pixels across a card decodes a picture at (its large view, all).
const _cardWidth = 2048;

class _ImageCard extends ConsumerStatefulWidget {
  const _ImageCard({super.key, required this.runId, required this.series});

  final String runId;
  final ImageSeries series;

  @override
  ConsumerState<_ImageCard> createState() => _ImageCardState();
}

class _ImageCardState extends ConsumerState<_ImageCard> {
  /// The step shown; null follows the latest one as new pictures arrive.
  int? _step;

  /// The last picture loaded, shown while the next one loads, so moving the
  /// slider doesn't flash a spinner at every step.
  LoggedImage? _shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = widget.series.steps;
    final index = _index(steps);
    final step = steps[index];
    final value = ref.watch(
      imageProvider((runId: widget.runId, name: widget.series.name, step: step.step)),
    );
    if (value.value case final loaded?) _shown = loaded;
    final shown = _shown;
    final caption = step.caption;
    return SectionCard(
      title: widget.series.name,
      trailing: Text(
        'Step ${formatInt(step.step)}',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: AspectRatio(
                aspectRatio: shown?.step == step.step && shown!.width > 0 && shown.height > 0
                    ? shown.width / shown.height
                    : step.aspectRatio,
                child: switch ((value, shown)) {
                  (AsyncValue(hasError: true, isLoading: false), _) => _Missing(
                    onRetry: () => ref.invalidate(
                      imageProvider((
                        runId: widget.runId,
                        name: widget.series.name,
                        step: step.step,
                      )),
                    ),
                  ),
                  (_, final image?) when !image.drawable => const _Missing(),
                  (_, final image?) => Semantics(
                    image: true,
                    label: [
                      '${widget.series.name} at step ${formatInt(image.step)}',
                      ?image.caption,
                    ].join(': '),
                    child: InkWell(
                      onTap: () => _openLarge(context, image),
                      child: Image.memory(
                        image.bytes,
                        // Decoded no bigger than a card shows.
                        cacheWidth: image.width > _cardWidth ? _cardWidth : null,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const _Missing(),
                      ),
                    ),
                  ),
                  _ => const Center(child: CircularProgressIndicator()),
                },
              ),
            ),
          ),
          if (caption != null && caption.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          if (steps.length > 1)
            Slider(
              value: index.toDouble(),
              max: (steps.length - 1).toDouble(),
              divisions: steps.length - 1,
              label: 'Step ${formatInt(step.step)}',
              semanticFormatterCallback: (_) => 'Step ${formatInt(step.step)}',
              onChanged: (i) => setState(
                () => _step = i.round() == steps.length - 1 ? null : steps[i.round()].step,
              ),
            ),
        ],
      ),
    );
  }

  int _index(List<ImageStep> steps) {
    if (_step == null) return steps.length - 1;
    final i = steps.indexWhere((s) => s.step == _step);
    return i < 0 ? steps.length - 1 : i;
  }

  void _openLarge(BuildContext context, LoggedImage image) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image.memory(
                  image.bytes,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  semanticLabel: '${image.name} at step ${formatInt(image.step)}',
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton.filledTonal(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text("Couldn't load this picture.", style: theme.textTheme.bodySmall),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
