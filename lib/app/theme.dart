import 'package:material_ui/material_ui.dart';

import '../models/run.dart';

/// The app's looks, picked in Settings. Each has a light and a dark theme.
enum AppStyle {
  paper('Paper', 'Cool grey, crimson, clean sans lettering'),
  ink('Ink', 'Typeset like a journal article: tables, figures, footnotes'),
  lab('Lab', 'An instrument panel: dot grid, readouts, monospace');

  const AppStyle(this.label, this.description);

  final String label;
  final String description;
}

/// One brightness of a style: its accent, its alert colour (crashed runs,
/// errors) and the seven neutrals the rest of the surfaces are mixed from.
class _Palette {
  const _Palette({
    required this.accent,
    required this.alert,
    required this.page,
    required this.panel,
    required this.raised,
    required this.text,
    required this.muted,
    required this.outline,
    required this.hairline,
  });

  final Color accent;
  final Color alert;

  /// The page behind everything.
  final Color page;

  /// Cards and the header, a step lighter (darker in the dark) than [page].
  final Color panel;

  /// Filled controls and wells, a step the other way.
  final Color raised;

  final Color text;
  final Color muted;
  final Color outline;
  final Color hairline;
}

/// What sets a style apart: colours, fonts and corner size.
class _Style {
  const _Style({
    required this.light,
    required this.dark,
    required this.bodyFont,
    required this.titleFont,
    required this.monoFont,
    required this.radius,
    this.header = _Header.panel,
  });

  final _Palette light;
  final _Palette dark;

  /// Everything but titles.
  final String bodyFont;

  /// Screen titles and large figures.
  final String titleFont;

  /// Code-like values: hyperparameters, layer names.
  final String monoFont;
  final double radius;
  final _Header header;
}

/// How a style's app bar looks.
enum _Header {
  /// A light panel with an accent line along the top (Paper).
  panel,

  /// The page itself, the title centred over a rule, like a paper's title
  /// (Ink).
  title,

  /// A dark bar with an accent rule below, like instrument software (Lab).
  bar,
}

/// Light and dark themes for each [AppStyle]: flat panels with hairline
/// borders, one accent colour, a distinct font for titles.
///
/// Everything is set here, once, so screens get the look from the theme
/// instead of styling widgets one by one. Themes are built once per style
/// and brightness, then reused.
abstract final class AppTheme {
  static const _styles = {
    AppStyle.paper: _Style(
      bodyFont: 'Inter',
      titleFont: 'Source Serif 4',
      monoFont: 'JetBrains Mono',
      radius: 4,
      light: _Palette(
        accent: Color(0xFF981B2B),
        alert: Color(0xFF981B2B),
        page: Color(0xFFECEEF0),
        panel: Color(0xFFF6F7F8),
        raised: Color(0xFFE1E5E9),
        text: Color(0xFF252A31),
        muted: Color(0xFF59616B),
        outline: Color(0xFF8A929C),
        hairline: Color(0xFFCFD4DA),
      ),
      // Slate, like the app icon's background.
      dark: _Palette(
        accent: Color(0xFFE4566A),
        alert: Color(0xFFE4566A),
        page: Color(0xFF16191D),
        panel: Color(0xFF1F2328),
        raised: Color(0xFF2A2F35),
        text: Color(0xFFE6E8EB),
        muted: Color(0xFF9AA2AC),
        outline: Color(0xFF6B737D),
        hairline: Color(0xFF323840),
      ),
    ),
    AppStyle.ink: _Style(
      // Typeset like a research paper: a journal typeface, links in the
      // dark blue of a LaTeX PDF, no boxes (panels are the page itself).
      bodyFont: 'STIX Two Text',
      titleFont: 'STIX Two Text',
      monoFont: 'JetBrains Mono',
      radius: 0,
      header: _Header.title,
      light: _Palette(
        accent: Color(0xFF1F3A8A),
        alert: Color(0xFF9B1C1C),
        page: Color(0xFFFDFCF8),
        panel: Color(0xFFFDFCF8),
        raised: Color(0xFFF0EDE5),
        text: Color(0xFF1A1A1A),
        muted: Color(0xFF555049),
        outline: Color(0xFF8F8A80),
        hairline: Color(0xFFD9D5CC),
      ),
      dark: _Palette(
        accent: Color(0xFF9DB4F5),
        alert: Color(0xFFF08A80),
        page: Color(0xFF16171B),
        panel: Color(0xFF16171B),
        raised: Color(0xFF26282E),
        text: Color(0xFFE8E6E1),
        muted: Color(0xFFA8A39A),
        outline: Color(0xFF6E6A64),
        hairline: Color(0xFF34363D),
      ),
    ),
    AppStyle.lab: _Style(
      // Monospace lettering throughout, like instrument software.
      bodyFont: 'IBM Plex Mono',
      titleFont: 'Space Grotesk',
      monoFont: 'IBM Plex Mono',
      radius: 2,
      header: _Header.bar,
      light: _Palette(
        accent: Color(0xFF0F766E),
        alert: Color(0xFFB42318),
        page: Color(0xFFF5F6F7),
        panel: Color(0xFFFFFFFF),
        raised: Color(0xFFEBEDEF),
        text: Color(0xFF111827),
        muted: Color(0xFF4B5563),
        outline: Color(0xFF9CA3AF),
        hairline: Color(0xFFE1E4E8),
      ),
      dark: _Palette(
        accent: Color(0xFF2DD4BF),
        alert: Color(0xFFF97066),
        page: Color(0xFF0E1113),
        panel: Color(0xFF161A1D),
        raised: Color(0xFF22282C),
        text: Color(0xFFE5E7EB),
        muted: Color(0xFF9CA3AF),
        outline: Color(0xFF6B7280),
        hairline: Color(0xFF2A3035),
      ),
    ),
  };

  static final _cache = <(AppStyle, Brightness), ThemeData>{};

  static ThemeData light([AppStyle style = AppStyle.paper]) => of(style, Brightness.light);

  static ThemeData dark([AppStyle style = AppStyle.paper]) => of(style, Brightness.dark);

  static ThemeData of(AppStyle style, Brightness brightness) =>
      _cache[(style, brightness)] ??= _build(style, brightness);

  static StyleTokens _tokens(BuildContext context) =>
      Theme.of(context).extension<StyleTokens>() ?? StyleTokens.fallback;

  /// The style on screen: the few widgets that are laid out differently per
  /// style (run cards, the runs list, panels) switch on it.
  static AppStyle styleOf(BuildContext context) => _tokens(context).style;

  /// Corner radius of panels, chips and buttons in the current style.
  static double radiusOf(BuildContext context) => _tokens(context).radius;

  /// The current style's font for code-like values.
  static String monoFontOf(BuildContext context) => _tokens(context).monoFont;

  /// Colours for text in the app bar, which in Lab is dark in both themes.
  static ({Color text, Color muted, bool dark}) headerColorsOf(BuildContext context) {
    final t = _tokens(context);
    final scheme = Theme.of(context).colorScheme;
    return t.darkHeader
        ? (text: const Color(0xFFE5E7EB), muted: const Color(0xFF9CA3AF), dark: true)
        : (
            text: scheme.onSurface,
            muted: scheme.onSurfaceVariant,
            dark: scheme.brightness == Brightness.dark,
          );
  }

  /// Lab's header bar, the same in light and dark.
  static const _barColor = Color(0xFF0B0D0F);

  static ColorScheme _scheme(_Palette p, Brightness brightness) {
    final light = brightness == Brightness.light;
    // Mixes of the palette's neutrals for the in-between surfaces.
    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    return ColorScheme.fromSeed(seedColor: p.accent, brightness: brightness).copyWith(
      primary: p.accent,
      onPrimary: light ? const Color(0xFFFFFFFF) : p.page,
      primaryContainer: mix(p.panel, p.accent, light ? 0.1 : 0.25),
      onPrimaryContainer: mix(p.text, p.accent, 0.5),
      secondaryContainer: p.raised,
      onSecondaryContainer: p.text,
      error: p.alert,
      onError: light ? const Color(0xFFFFFFFF) : p.page,
      errorContainer: mix(p.panel, p.alert, light ? 0.12 : 0.25),
      onErrorContainer: mix(p.text, p.alert, light ? 0.6 : 0.3),
      surface: p.page,
      surfaceDim: mix(p.page, p.raised, 0.5),
      surfaceBright: p.panel,
      surfaceContainerLowest: light
          ? mix(p.panel, const Color(0xFFFFFFFF), 0.5)
          : mix(p.page, const Color(0xFF000000), 0.3),
      surfaceContainerLow: p.panel,
      surfaceContainer: mix(p.page, p.raised, 0.4),
      surfaceContainerHigh: mix(p.page, p.raised, 0.7),
      surfaceContainerHighest: p.raised,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
      outline: p.outline,
      outlineVariant: p.hairline,
    );
  }

  static ThemeData _build(AppStyle appStyle, Brightness brightness) {
    final style = _styles[appStyle]!;
    final scheme = _scheme(brightness == Brightness.light ? style.light : style.dark, brightness);
    final bar = style.header == _Header.bar;
    final barAccent = bar ? _styles[appStyle]!.dark.accent : scheme.primary;
    final base = ThemeData(colorScheme: scheme, fontFamily: style.bodyFont);
    final text = base.textTheme;
    TextStyle? titled(TextStyle? s) =>
        s?.copyWith(fontFamily: style.titleFont, fontWeight: FontWeight.w500);
    final corners = RoundedRectangleBorder(borderRadius: BorderRadius.circular(style.radius));
    final hairline = BorderSide(color: scheme.outlineVariant);
    final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(corners);

    return base.copyWith(
      extensions: [
        StyleTokens(
          style: appStyle,
          radius: style.radius,
          monoFont: style.monoFont,
          darkHeader: bar,
        ),
      ],
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text.copyWith(
        displayLarge: titled(text.displayLarge),
        displayMedium: titled(text.displayMedium),
        displaySmall: titled(text.displaySmall),
        headlineLarge: titled(text.headlineLarge),
        headlineMedium: titled(text.headlineMedium),
        headlineSmall: titled(text.headlineSmall),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: switch (style.header) {
          _Header.panel => scheme.surfaceContainerLow,
          _Header.title => scheme.surface,
          _Header.bar => _barColor,
        },
        foregroundColor: bar ? const Color(0xFFE5E7EB) : scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: style.header == _Header.title,
        shape: switch (style.header) {
          _Header.panel => Border(
            top: BorderSide(color: scheme.primary, width: 3),
            bottom: hairline,
          ),
          _Header.title => Border(bottom: BorderSide(color: scheme.onSurface, width: 1.2)),
          _Header.bar => Border(bottom: BorderSide(color: barAccent, width: 2)),
        },
        titleTextStyle: TextStyle(
          fontFamily: style.titleFont,
          fontSize: bar ? 20 : 22,
          fontWeight: FontWeight.w500,
          color: bar ? const Color(0xFFE5E7EB) : scheme.onSurface,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: barAccent,
        unselectedLabelColor: bar ? const Color(0xFF9CA3AF) : scheme.onSurfaceVariant,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: barAccent, width: style.header == _Header.title ? 1.2 : 2),
        ),
        // The app bar's own hairline is the divider.
        dividerHeight: 0,
        labelStyle: TextStyle(
          fontFamily: style.bodyFont,
          fontSize: bar ? 12 : 14,
          fontWeight: FontWeight.w600,
          letterSpacing: bar ? 1 : 0,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: style.bodyFont,
          fontSize: bar ? 12 : 14,
          fontWeight: FontWeight.w500,
          letterSpacing: bar ? 1 : 0,
        ),
      ),
      // The sections (Runs, Compute): flat, the open one in the accent.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bar ? _barColor : scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: barAccent.withValues(alpha: bar ? 0.22 : 0.12),
        indicatorShape: corners,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? barAccent
                : (bar ? const Color(0xFF9CA3AF) : scheme.onSurfaceVariant),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: style.bodyFont,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? barAccent
                : (bar ? const Color(0xFF9CA3AF) : scheme.onSurfaceVariant),
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: bar ? _barColor : scheme.surfaceContainerLow,
        indicatorColor: barAccent.withValues(alpha: bar ? 0.22 : 0.12),
        indicatorShape: corners,
        selectedIconTheme: IconThemeData(color: barAccent),
        unselectedIconTheme: IconThemeData(
          color: bar ? const Color(0xFF9CA3AF) : scheme.onSurfaceVariant,
        ),
        selectedLabelTextStyle: TextStyle(
          fontFamily: style.bodyFont,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: barAccent,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: style.bodyFont,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: bar ? const Color(0xFF9CA3AF) : scheme.onSurfaceVariant,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: corners.copyWith(side: hairline),
      ),
      chipTheme: ChipThemeData(shape: corners, side: hairline),
      filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(shape: buttonShape)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: ButtonStyle(shape: buttonShape)),
      textButtonTheme: TextButtonThemeData(style: ButtonStyle(shape: buttonShape)),
      segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(shape: buttonShape)),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    );
  }
}

/// Style values the theme has no slot for, read through [AppTheme]
/// (`styleOf`, `radiusOf`, ...).
class StyleTokens extends ThemeExtension<StyleTokens> {
  const StyleTokens({
    required this.style,
    required this.radius,
    required this.monoFont,
    required this.darkHeader,
  });

  static const fallback = StyleTokens(
    style: AppStyle.paper,
    radius: 4,
    monoFont: 'JetBrains Mono',
    darkHeader: false,
  );

  final AppStyle style;
  final double radius;
  final String monoFont;

  /// Whether the app bar is dark whatever the theme (Lab).
  final bool darkHeader;

  @override
  StyleTokens copyWith({AppStyle? style, double? radius, String? monoFont, bool? darkHeader}) =>
      StyleTokens(
        style: style ?? this.style,
        radius: radius ?? this.radius,
        monoFont: monoFont ?? this.monoFont,
        darkHeader: darkHeader ?? this.darkHeader,
      );

  // Styles switch at once rather than blend.
  @override
  StyleTokens lerp(StyleTokens? other, double t) => other == null || t < 0.5 ? this : other;
}

/// Text styles the theme's text theme has no slot for.
abstract final class AppText {
  /// Numbers that line up in columns and don't jiggle as they update.
  static const tabular = [FontFeature.tabularFigures()];

  /// A small, spaced-out capitals label, as on the site's section headings.
  /// Pass the text through [eyebrowCase].
  /// In the style's body font, which it inherits.
  static TextStyle eyebrow(ColorScheme scheme, {Color? color}) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.3,
    height: 1.3,
    color: color ?? scheme.primary,
  );

  static String eyebrowCase(String text) => text.toUpperCase();

  /// Hyperparameter values, layer names and other code-like text.
  static TextStyle mono(BuildContext context) => TextStyle(
    fontFamily: AppTheme.monoFontOf(context),
    fontSize: 13,
    height: 1.4,
    color: Theme.of(context).colorScheme.onSurface,
  );
}

/// Colours that carry the same meaning in every chart of the app.
abstract final class ChartColors {
  static const train = Color(0xFF378ADD);
  static const validation = Color(0xFFD85A30);
  static const accuracy = Color(0xFF1D9E75);
  static const learningRate = Color(0xFFBA7517);
  static const gradient = Color(0xFF7F77DD);
  static const activation = Color(0xFF1D9E75);
  static const other = Color(0xFF888780);

  /// One per run on the compare screen, in order.
  static const runs = [
    Color(0xFF378ADD),
    Color(0xFFD85A30),
    Color(0xFF1D9E75),
    Color(0xFF7F77DD),
    Color(0xFFBA7517),
    Color(0xFFD4537E),
  ];
}

/// Colour and label for each [RunStatus].
extension RunStatusStyle on RunStatus {
  String get label => switch (this) {
    RunStatus.live => 'Live',
    RunStatus.finished => 'Finished',
    RunStatus.crashed => 'Crashed',
  };

  /// Text and accent colour of the status. Chosen per brightness so small
  /// text keeps at least 4.5:1 contrast on its own tinted background
  /// (see `StatusChip`).
  Color color(ColorScheme scheme) => switch (this) {
    RunStatus.live =>
      scheme.brightness == Brightness.light ? const Color(0xFF0A6649) : const Color(0xFF6FDDB5),
    RunStatus.finished => scheme.onSurfaceVariant,
    RunStatus.crashed => scheme.error,
  };
}
