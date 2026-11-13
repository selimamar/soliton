import 'package:material_ui/material_ui.dart';

import '../models/run.dart';

/// Light and dark Material 3 themes built from a single seed colour.
abstract final class AppTheme {
  static const seedColor = Color(0xFF3E63DD);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    var scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
    if (brightness == Brightness.light) scheme = _paperNeutrals(scheme);
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
    );
  }

  /// Cool grey neutrals for the light theme, matching selimamar.github.io:
  /// a #ECEEF0 page with lighter #F6F7F8 panels (cards sit on
  /// surfaceContainerLow), slate text and #CFD4DA hairlines. The seeded
  /// accent colours are left alone.
  static ColorScheme _paperNeutrals(ColorScheme scheme) => scheme.copyWith(
    surface: const Color(0xFFECEEF0),
    surfaceDim: const Color(0xFFD9DDE1),
    surfaceBright: const Color(0xFFF6F7F8),
    surfaceContainerLowest: const Color(0xFFFBFBFC),
    surfaceContainerLow: const Color(0xFFF6F7F8),
    surfaceContainer: const Color(0xFFE6E9EC),
    surfaceContainerHigh: const Color(0xFFE1E5E9),
    surfaceContainerHighest: const Color(0xFFDBE0E5),
    onSurface: const Color(0xFF252A31),
    onSurfaceVariant: const Color(0xFF59616B),
    outline: const Color(0xFF8A929C),
    outlineVariant: const Color(0xFFCFD4DA),
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
    RunStatus.crashed =>
      scheme.brightness == Brightness.light ? const Color(0xFF981B2B) : scheme.error,
  };
}
