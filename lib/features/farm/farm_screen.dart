import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../shared/clock.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/sparkline.dart';
import '../../shared/widgets/stat_tile.dart';
import '../../shared/widgets/status_chip.dart';
import 'farm_painter.dart';
import 'farm_palette.dart';
import 'farm_settings.dart';
import 'farm_settings_section.dart';
import 'farm_sky.dart';
import 'farm_world.dart';

/// The runs as a farm: an animal for each finished run, as big as its
/// model, walking about (a duck, or the animal its model family is set to
/// in the farm's settings); an egg in the nest for each live run, filling
/// its ring as it trains and hatching when it finishes. Tap one for its
/// figures and a way to the full analysis.
///
/// The farm keeps the app's clock: its light fades smoothly from day to
/// night (the animals fall asleep, the coop's lamp comes on), and the
/// season sets its colours and weather.
///
/// With reduced motion (or a screen reader) the ducks stand still in rows.
///
/// Works the way each platform expects: a tap gives a light haptic tick on
/// phones; Back (Android's gesture or button) and Esc (desktop keyboards)
/// close the sheet before leaving the farm; and a mouse pointer turns into
/// a hand over anything it can open.
class FarmScreen extends ConsumerStatefulWidget {
  const FarmScreen({super.key, this.seed = 7});

  /// Seeds where ducks wander, so tests see the same farm every time.
  final int seed;

  @override
  ConsumerState<FarmScreen> createState() => _FarmScreenState();
}

class _FarmScreenState extends ConsumerState<FarmScreen> with SingleTickerProviderStateMixin {
  late final FarmWorld _world = FarmWorld(seed: widget.seed);
  final _text = FarmTextCache();
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still =
        MediaQuery.disableAnimationsOf(context) || MediaQuery.accessibleNavigationOf(context);
    _world.setAnimate(!still);
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
    // The style or theme may have changed: labels are laid out afresh.
    _text.clear();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _world.update(dt.clamp(0, 0.05));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _world.dispose();
    _text.clear();
    super.dispose();
  }

  /// Whether the mouse is over a duck or an egg (desktop, web, tablets
  /// with a pointer).
  bool _overRun = false;

  void _select(String? id) {
    if (id != null && id != _world.selectedId) HapticFeedback.selectionClick();
    setState(() => _world.select(id));
  }

  void _hover(Offset position) {
    final over = _world.hitTest(position) != null;
    if (over != _overRun) setState(() => _overRun = over);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // With a run's sheet up, Back closes the sheet rather than the farm.
    canPop: _world.selectedId == null,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _select(null);
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_world.selectedId != null) _select(null);
        },
      },
      child: Focus(autofocus: true, child: _scaffold()),
    ),
  );

  Widget _scaffold() => Scaffold(
    appBar: AppBar(
      title: const Text('Farm'),
      actions: [
        IconButton(
          icon: const Icon(Icons.tune),
          tooltip: 'Farm settings',
          onPressed: () => showFarmSettings(context),
        ),
        IconButton(
          icon: const Icon(Icons.view_list_outlined),
          tooltip: 'Runs as a list',
          onPressed: () => context.go(AppRoutes.runs),
        ),
      ],
    ),
    body: AsyncValueView(
      value: ref.watch(runsProvider),
      keepDataWhileReloading: !ref.watch(allRunsProvider).isReloading,
      onRetry: () => ref.invalidate(allRunsProvider),
      data: _farm,
    ),
  );

  Widget _farm(List<Run> runs) {
    final theme = Theme.of(context);
    final sky = FarmSky.at(
      ref.watch(clockProvider),
      hemisphere: ref.watch(farmHemisphereProvider),
      timeOfDay: ref.watch(farmTimeOfDayProvider),
    );
    final animals = ref.watch(farmAnimalsProvider);
    final palette = FarmPalette.of(context).seasoned(sky.season);
    final style = AppTheme.styleOf(context);
    final labelStyle = switch (style) {
      AppStyle.ink => TextStyle(
        fontFamily: theme.textTheme.bodyMedium?.fontFamily,
        fontStyle: FontStyle.italic,
        fontSize: 13.5,
        color: palette.text,
      ),
      _ => TextStyle(
        fontFamily: AppTheme.monoFontOf(context),
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: palette.accent,
      ),
    };
    final selected = runs.where((r) => r.id == _world.selectedId).firstOrNull;
    final duckIndex = _world.ducks.indexWhere((d) => d.id == selected?.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FarmCaption(runs: runs, palette: palette, animals: animals, sky: sky),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _world
                      ..resize(
                        constraints.biggest,
                        bottomInset: MediaQuery.paddingOf(context).bottom,
                      )
                      ..setAnimals(animals)
                      ..sync(runs)
                      ..setSky(sky);
                    return MouseRegion(
                      cursor: _overRun ? SystemMouseCursors.click : MouseCursor.defer,
                      onEnter: (event) => _hover(event.localPosition),
                      onHover: (event) => _hover(event.localPosition),
                      onExit: (_) => _hover(const Offset(-1e6, -1e6)),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _select(_world.hitTest(details.localPosition)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                painter: FarmScenePainter(
                                  layout: _world.layout,
                                  palette: palette,
                                  labelStyle: labelStyle,
                                  season: sky.season,
                                ),
                              ),
                            ),
                            CustomPaint(
                              painter: FarmCreaturesPainter(
                                world: _world,
                                palette: palette,
                                labelStyle: labelStyle,
                                text: _text,
                                onSelect: _select,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(animation),
                    child: child,
                  ),
                  child: selected == null
                      ? const SizedBox.shrink()
                      : Center(
                          key: ValueKey(selected.id),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: _RunSheet(
                              run: selected,
                              label: selected.status == RunStatus.finished && duckIndex >= 0
                                  ? farmLabel(style, duckIndex)
                                  : null,
                              onClose: () => _select(null),
                            ),
                          ),
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

/// The line above the farm: how many runs are ducks, eggs and cracked
/// eggs, and (Paper, Ink) which colour is which model. Ink writes it as a
/// figure caption.
class _FarmCaption extends StatelessWidget {
  const _FarmCaption({
    required this.runs,
    required this.palette,
    required this.animals,
    required this.sky,
  });

  final List<Run> runs;
  final FarmPalette palette;

  /// Which animal each family is: families that aren't ducks are named in
  /// the legend with their animal, e.g. "FNO (beavers)".
  final Map<String, FarmAnimal> animals;
  final FarmSky sky;

  /// "dawn", "day", "dusk" or "night".
  String get _timeOfDay => sky.light > 0.95
      ? 'day'
      : sky.light < 0.05
      ? 'night'
      : sky.sun < 0.5
      ? 'dawn'
      : 'dusk';

  static const _words = [
    'no', 'one', 'two', 'three', 'four', 'five', 'six', //
    'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
  ];

  static String _word(int n) => n < _words.length ? _words[n] : '$n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    int count(RunStatus s) => runs.where((r) => r.status == s).length;
    final finished = count(RunStatus.finished);
    final live = count(RunStatus.live);
    final crashed = count(RunStatus.crashed);
    final families = {for (final run in runs) ?FarmWorld.familyOf(run)}.toList()..sort();
    final base = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final strong = TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface);

    final Widget summary = switch (style) {
      AppStyle.paper => Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$finished', style: strong),
            const TextSpan(text: ' finished · '),
            TextSpan(text: '$live', style: strong),
            const TextSpan(text: ' training · '),
            TextSpan(
              text: '$crashed',
              style: strong.copyWith(color: crashed > 0 ? scheme.error : null),
            ),
            const TextSpan(text: ' crashed'),
            TextSpan(text: ' · ${sky.season.label}, $_timeOfDay'),
          ],
        ),
        style: base?.copyWith(fontFeatures: AppText.tabular),
      ),
      AppStyle.ink => Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'Figure 1. ',
              style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurface),
            ),
            TextSpan(text: _inkSentence(finished, live, crashed)),
            if (crashed > 0)
              TextSpan(
                text: '†',
                style: TextStyle(color: scheme.error),
              ),
            TextSpan(
              text: ' ${sky.season.label}, ${_timeOfDay == 'day' ? 'by day' : 'at $_timeOfDay'}.',
            ),
          ],
        ),
        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
      ),
      AppStyle.lab => Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'TRAINED '),
            TextSpan(
              text: _two(finished),
              style: TextStyle(color: scheme.onSurface),
            ),
            const TextSpan(text: ' · LIVE '),
            TextSpan(
              text: _two(live),
              style: TextStyle(color: scheme.primary),
            ),
            const TextSpan(text: ' · ERR '),
            TextSpan(
              text: _two(crashed),
              style: TextStyle(color: scheme.error),
            ),
            TextSpan(
              text:
                  ' · ${sky.season.label.toUpperCase()} ${_timeOfDay.toUpperCase()} '
                  '· LUX ${(sky.light * 100).round().toString().padLeft(3, '0')}',
            ),
          ],
        ),
        semanticsLabel:
            '$finished trained, $live live, $crashed crashed. '
            '${sky.season.label}, $_timeOfDay',
        style: base?.copyWith(letterSpacing: 0.5, fontFeatures: AppText.tabular),
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          summary,
          // Lab's ducks are all alike (they carry numbers instead).
          if (style != AppStyle.lab && families.length > 1) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                for (final (i, family) in families.indexed)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Only ducks carry their family's colour.
                      if (animals[family] == null) ...[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: palette.family(i).$1,
                            shape: style == AppStyle.ink ? BoxShape.rectangle : BoxShape.circle,
                            border: Border.all(
                              color: palette.line ?? scheme.outline,
                              width: style == AppStyle.ink ? 0.8 : 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(switch (animals[family]) {
                        final animal? => '$family (${animal.plural})',
                        null => family,
                      }, style: base),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "Five finished runs (a–e), two training and one crashed."
  static String _inkSentence(int finished, int live, int crashed) {
    String letter(int i) => farmLabel(AppStyle.ink, i)!.replaceAll(RegExp('[()]'), '');
    final ducks = switch (finished) {
      0 => 'No finished runs',
      1 => 'One finished run (a)',
      _ =>
        '${_word(finished)[0].toUpperCase()}${_word(finished).substring(1)} '
            'finished runs (a–${letter(finished - 1)})',
    };
    return '$ducks, ${_word(live)} training and ${_word(crashed)} crashed.';
  }
}

/// The figures of the run tapped on, sliding up from the bottom, with the
/// way to its full analysis.
class _RunSheet extends ConsumerWidget {
  const _RunSheet({required this.run, required this.label, required this.onClose});

  final Run run;

  /// The duck's label in the figure, e.g. "(c)" in Ink.
  final String? label;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    final now = ref.watch(clockProvider);
    final params = run.parameterCount > 0 ? formatCount(run.parameterCount) : '—';
    String loss() => run.latestLoss == null ? '—' : formatMetric(run.latestLoss!);
    final stats = switch (run.status) {
      RunStatus.finished => [
        ('Parameters', params),
        ('Final loss', loss()),
        if (run.epochText case final epochs?)
          ('Epochs', epochs)
        else
          ('Steps', formatInt(run.currentStep)),
        ('Took', formatDuration(run.elapsedAt(now))),
      ],
      RunStatus.queued => [
        ('Waiting', formatRoughDuration(run.queuedFor(now) ?? Duration.zero)),
        ('Reason', run.system?.queueReason ?? '—'),
      ],
      RunStatus.live => [
        ('Parameters', params),
        ('Loss now', loss()),
        ('Trained', run.hasEnd ? formatPercent(run.progress) : '—'),
        (
          'Hatches in',
          switch (run.estimatedRemainingAt(now)) {
            final left? => formatDuration(left),
            null => '—',
          },
        ),
      ],
      RunStatus.crashed => [
        ('Parameters', params),
        ('Last loss', loss()),
        if (run.hasEnd)
          ('Stopped at', formatPercent(run.progress))
        else
          ('Stopped at', 'step ${formatInt(run.currentStep)}'),
        ('Ran for', formatDuration(run.elapsedAt(now))),
      ],
    };
    final (action, location) = switch (run.status) {
      RunStatus.queued => ('See its place in the queue', AppRoutes.run(run.id)),
      RunStatus.finished => ('Open full analysis', AppRoutes.run(run.id)),
      RunStatus.live => ('Watch it train', '${AppRoutes.run(run.id)}?tab=metrics'),
      RunStatus.crashed => ('See what went wrong', AppRoutes.run(run.id)),
    };
    void open() => context.go(location);

    final radius = Radius.circular(AppTheme.radiusOf(context));
    final decoration = switch (style) {
      AppStyle.paper => BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(top: radius),
        border: Border(top: BorderSide(color: scheme.primary, width: 2)),
      ),
      AppStyle.ink => BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.onSurface, width: 1.5)),
      ),
      AppStyle.lab => BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(top: radius),
        border: Border(top: BorderSide(color: scheme.primary, width: 2)),
      ),
    };

    final button = switch (style) {
      AppStyle.paper => FilledButton(onPressed: open, child: Text(action)),
      AppStyle.ink => TextButton(
        onPressed: open,
        child: Text(
          '$action →',
          semanticsLabel: action,
          style: const TextStyle(decoration: TextDecoration.underline, fontSize: 15),
        ),
      ),
      AppStyle.lab => OutlinedButton(
        onPressed: open,
        child: Text('> ${action.toLowerCase()}', semanticsLabel: action),
      ),
    };

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: decoration,
        padding: EdgeInsets.fromLTRB(16, 8, 4, 16 + MediaQuery.paddingOf(context).bottom),
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (style == AppStyle.ink)
                          Text(
                            switch (run.status) {
                              RunStatus.queued => 'Run in the queue',
                              RunStatus.finished => 'Run ${label ?? ''}'.trim(),
                              RunStatus.live => 'Run in progress',
                              RunStatus.crashed => 'Run †',
                            },
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        Text(
                          style == AppStyle.lab && label != null
                              ? '$label · ${run.name}'
                              : run.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontFamily: theme.textTheme.headlineSmall?.fontFamily,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusChip(status: run.status),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Close',
                    onPressed: onClose,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              StatStrip(stats: stats),
              if (run.lossPreview.length > 1) ...[
                const SizedBox(height: 10),
                Sparkline(
                  values: run.lossPreview,
                  color: scheme.primary,
                  height: 36,
                  grid: style == AppStyle.lab,
                  semanticLabel: 'Loss curve',
                ),
              ],
              if (run.status == RunStatus.crashed && run.statusMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  style == AppStyle.ink ? '† ${run.statusMessage}' : run.statusMessage!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(height: 48, child: button),
            ],
          ),
        ),
      ),
    );
  }
}
