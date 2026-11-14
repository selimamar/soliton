import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';

/// The farm's colours in one style and brightness.
///
/// Paper is flat colour in its cool greys and crimson; Ink is fine outlines
/// over soft print tones, like a figure in a journal; Lab is an instrument
/// map, outlines on a dot grid in teal. The accent, text and alert colours
/// come from the app's theme, so the farm matches the screens around it.
class FarmPalette {
  const FarmPalette({
    required this.style,
    required this.dark,
    required this.ground,
    required this.groundMark,
    required this.path,
    required this.roof,
    required this.roofShade,
    required this.nest,
    required this.nestInner,
    required this.straw,
    required this.water,
    required this.waterLight,
    required this.waterMark,
    required this.tree,
    required this.treeLight,
    required this.border,
    required this.line,
    required this.shadow,
    required this.ripple,
    required this.families,
    required this.unknownFamily,
    required this.bill,
    required this.billShade,
    required this.eye,
    required this.shell,
    required this.shellShade,
    required this.crashedShell,
    required this.crashedShade,
    required this.ringTrack,
    required this.accent,
    required this.alert,
    required this.text,
    required this.muted,
  });

  factory FarmPalette.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return switch (AppTheme.styleOf(context)) {
      AppStyle.paper => dark ? _paperDark(scheme) : _paperLight(scheme),
      AppStyle.ink => dark ? _inkDark(scheme) : _inkLight(scheme),
      AppStyle.lab => dark ? _labDark(scheme) : _labLight(scheme),
    };
  }

  final AppStyle style;
  final bool dark;

  /// Grass (Paper), the page (Ink) or the map's background (Lab).
  final Color ground;

  /// Dots of grass, stipple or the grid.
  final Color groundMark;
  final Color path;
  final Color roof;
  final Color roofShade;
  final Color nest;
  final Color nestInner;
  final Color straw;
  final Color water;
  final Color waterLight;
  final Color waterMark;
  final Color tree;
  final Color treeLight;
  final Color border;

  /// The outline drawn round everything (Ink, Lab); null for none (Paper).
  final Color? line;
  final Color shadow;
  final Color ripple;

  /// A duck's (body, shade) by its model type, in turn.
  final List<(Color, Color)> families;

  /// For runs whose model type wasn't logged.
  final (Color, Color) unknownFamily;
  final Color bill;
  final Color billShade;
  final Color eye;
  final Color shell;
  final Color shellShade;
  final Color crashedShell;
  final Color crashedShade;
  final Color ringTrack;
  final Color accent;
  final Color alert;
  final Color text;
  final Color muted;

  (Color, Color) family(int index) => index < 0 ? unknownFamily : families[index % families.length];

  static FarmPalette _paperLight(ColorScheme s) => FarmPalette(
    style: AppStyle.paper,
    dark: false,
    ground: const Color(0xFFC9D5C5),
    groundMark: const Color(0xFFB8C7B3),
    path: const Color(0xFFE4E7EA),
    roof: s.primary,
    roofShade: Color.lerp(s.primary, Colors.black, 0.18)!,
    nest: const Color(0xFFD9CFB8),
    nestInner: const Color(0xFFC2B697),
    straw: const Color(0xFFE8E0CC),
    water: const Color(0xFF9FB6C7),
    waterLight: const Color(0xFFB9CCDA),
    waterMark: const Color(0xFFFFFFFF),
    tree: const Color(0xFFA4B99F),
    treeLight: const Color(0xFFB4C7AF),
    border: s.outline,
    line: null,
    shadow: const Color(0x29252A31),
    ripple: const Color(0xFFFFFFFF),
    families: const [
      (Color(0xFFF1C75B), Color(0xFFD8A93A)),
      (Color(0xFFFAFBFC), Color(0xFFD5DAE0)),
      (Color(0xFFA9B8C6), Color(0xFF8798A9)),
      (Color(0xFFE7C3A6), Color(0xFFCFA283)),
      (Color(0xFFB9C9A8), Color(0xFF98AC85)),
      (Color(0xFFE3B5B9), Color(0xFFC99398)),
    ],
    unknownFamily: (const Color(0xFFE1E5E9), const Color(0xFFC3C9D0)),
    bill: const Color(0xFFE0784C),
    billShade: const Color(0xFFC25E35),
    eye: s.onSurface,
    shell: const Color(0xFFFAFBFC),
    shellShade: const Color(0xFFE1E5E9),
    crashedShell: const Color(0xFFB5BBC2),
    crashedShade: const Color(0xFF9AA1A9),
    ringTrack: const Color(0x99FFFFFF),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );

  static FarmPalette _paperDark(ColorScheme s) => FarmPalette(
    style: AppStyle.paper,
    dark: true,
    ground: const Color(0xFF26302A),
    groundMark: const Color(0xFF2F3A33),
    path: const Color(0xFF2E343B),
    roof: const Color(0xFFA8323F),
    roofShade: const Color(0xFF86232F),
    nest: const Color(0xFF4A4436),
    nestInner: const Color(0xFF3B3629),
    straw: const Color(0xFF5E5644),
    water: const Color(0xFF2C3F4E),
    waterLight: const Color(0xFF3A5466),
    waterMark: const Color(0xFF6F8CA3),
    tree: const Color(0xFF33443A),
    treeLight: const Color(0xFF3D5045),
    border: s.outline,
    line: null,
    shadow: const Color(0x4D000000),
    ripple: const Color(0xFF8FA9BD),
    families: const [
      (Color(0xFFDDB24F), Color(0xFFB8912F)),
      (Color(0xFFE6E8EB), Color(0xFFBFC5CC)),
      (Color(0xFF93A5B6), Color(0xFF74879A)),
      (Color(0xFFD5AF91), Color(0xFFB58E70)),
      (Color(0xFFA3B592), Color(0xFF839670)),
      (Color(0xFFD29EA3), Color(0xFFB27D83)),
    ],
    unknownFamily: (const Color(0xFFAEB5BD), const Color(0xFF8E959E)),
    bill: const Color(0xFFD9764A),
    billShade: const Color(0xFFB45C34),
    eye: const Color(0xFF1F2328),
    shell: const Color(0xFFE6E8EB),
    shellShade: const Color(0xFFBFC5CC),
    crashedShell: const Color(0xFF6B737D),
    crashedShade: const Color(0xFF575E67),
    ringTrack: const Color(0x40FFFFFF),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );

  static FarmPalette _inkLight(ColorScheme s) => FarmPalette(
    style: AppStyle.ink,
    dark: false,
    ground: s.surface,
    groundMark: const Color(0xFFBDB6A8),
    path: const Color(0xFFF4EFE4),
    roof: const Color(0xFFFFFFFF),
    roofShade: const Color(0xFFF1EDE4),
    nest: const Color(0xFFF3EAD2),
    nestInner: const Color(0xFFE9DCB8),
    straw: const Color(0xFFB39A6B),
    water: const Color(0xFFE6EEF5),
    waterLight: const Color(0xFFE6EEF5),
    waterMark: const Color(0xFF8FA3BF),
    tree: const Color(0xFFEAEFE2),
    treeLight: const Color(0xFF98A38A),
    border: const Color(0xFF2B2A28),
    line: const Color(0xFF2B2A28),
    shadow: const Color(0x1F2B2A28),
    ripple: const Color(0xFF8FA3BF),
    families: const [
      (Color(0xFFF5E7BF), Color(0xFFE6D29A)),
      (Color(0xFFFFFFFF), Color(0xFFE9E5DC)),
      (Color(0xFFDEE6F1), Color(0xFFC1CFE2)),
      (Color(0xFFF2DFCF), Color(0xFFE0C5AE)),
      (Color(0xFFE3EBD8), Color(0xFFC9D6B8)),
      (Color(0xFFF1DCE0), Color(0xFFDFC0C6)),
    ],
    unknownFamily: (const Color(0xFFF0EDE5), const Color(0xFFDDD8CD)),
    bill: const Color(0xFFEBB585),
    billShade: const Color(0xFF2B2A28),
    eye: const Color(0xFF1A1A1A),
    shell: const Color(0xFFFFFFFF),
    shellShade: const Color(0xFFEFEBE2),
    crashedShell: const Color(0xFFECE9E3),
    crashedShade: const Color(0xFFDCD8D0),
    ringTrack: const Color(0xFFE4E0D6),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );

  static FarmPalette _inkDark(ColorScheme s) => FarmPalette(
    style: AppStyle.ink,
    dark: true,
    ground: s.surface,
    groundMark: const Color(0xFF4A4C52),
    path: const Color(0xFF1E2024),
    roof: const Color(0xFF1E2024),
    roofShade: const Color(0xFF26282E),
    nest: const Color(0xFF2E2A22),
    nestInner: const Color(0xFF3A3428),
    straw: const Color(0xFF8C7A57),
    water: const Color(0xFF1C2430),
    waterLight: const Color(0xFF1C2430),
    waterMark: const Color(0xFF5E7396),
    tree: const Color(0xFF1F2620),
    treeLight: const Color(0xFF5F6B58),
    border: const Color(0xFFCFCAC0),
    line: const Color(0xFFCFCAC0),
    shadow: const Color(0x40000000),
    ripple: const Color(0xFF7189B3),
    families: const [
      (Color(0xFF615640), Color(0xFF4D4433)),
      (Color(0xFF494C55), Color(0xFF3A3D44)),
      (Color(0xFF3D4D66), Color(0xFF313F54)),
      (Color(0xFF614E40), Color(0xFF4E3F33)),
      (Color(0xFF44543C), Color(0xFF374530)),
      (Color(0xFF5E4550), Color(0xFF4C3841)),
    ],
    unknownFamily: (const Color(0xFF2A2C32), const Color(0xFF222429)),
    bill: const Color(0xFF8C6446),
    billShade: const Color(0xFFCFCAC0),
    eye: const Color(0xFFE8E6E1),
    shell: const Color(0xFF26282E),
    shellShade: const Color(0xFF1E2024),
    crashedShell: const Color(0xFF1E2024),
    crashedShade: const Color(0xFF1A1B1F),
    ringTrack: const Color(0xFF34363D),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );

  static FarmPalette _labLight(ColorScheme s) => FarmPalette(
    style: AppStyle.lab,
    dark: false,
    ground: s.surface,
    groundMark: const Color(0xFFD3D7DC),
    path: const Color(0xFF9CA3AF),
    roof: const Color(0xFFFFFFFF),
    roofShade: const Color(0xFFFFFFFF),
    nest: const Color(0xFFFFFFFF),
    nestInner: const Color(0xFFFFFFFF),
    straw: const Color(0xFFFFFFFF),
    water: Color.lerp(s.surface, s.primary, 0.08)!,
    waterLight: Color.lerp(s.surface, s.primary, 0.08)!,
    waterMark: s.primary,
    tree: const Color(0x00000000),
    treeLight: const Color(0xFF9CA3AF),
    border: const Color(0xFF9CA3AF),
    line: const Color(0xFF111827),
    shadow: const Color(0x1F111827),
    ripple: s.primary,
    families: const [(Color(0xFFFFFFFF), Color(0xFFE1E4E8))],
    unknownFamily: (const Color(0xFFFFFFFF), const Color(0xFFE1E4E8)),
    bill: s.primary,
    billShade: Color.lerp(s.primary, Colors.black, 0.25)!,
    eye: const Color(0xFF111827),
    shell: const Color(0xFFFFFFFF),
    shellShade: const Color(0xFFFFFFFF),
    crashedShell: const Color(0xFFFFFFFF),
    crashedShade: const Color(0xFFFFFFFF),
    ringTrack: const Color(0xFFE1E4E8),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );

  static FarmPalette _labDark(ColorScheme s) => FarmPalette(
    style: AppStyle.lab,
    dark: true,
    ground: s.surface,
    groundMark: const Color(0xFF22282C),
    path: const Color(0xFF6B7280),
    roof: const Color(0xFF161A1D),
    roofShade: const Color(0xFF161A1D),
    nest: const Color(0xFF161A1D),
    nestInner: const Color(0xFF161A1D),
    straw: const Color(0xFF161A1D),
    water: Color.lerp(s.surface, s.primary, 0.08)!,
    waterLight: Color.lerp(s.surface, s.primary, 0.08)!,
    waterMark: s.primary,
    tree: const Color(0x00000000),
    treeLight: const Color(0xFF6B7280),
    border: const Color(0xFF6B7280),
    line: const Color(0xFFE5E7EB),
    shadow: const Color(0x40000000),
    ripple: s.primary,
    families: const [(Color(0xFF161A1D), Color(0xFF2A3035))],
    unknownFamily: (const Color(0xFF161A1D), const Color(0xFF2A3035)),
    bill: s.primary,
    billShade: Color.lerp(s.primary, Colors.black, 0.35)!,
    eye: const Color(0xFFE5E7EB),
    shell: const Color(0xFF161A1D),
    shellShade: const Color(0xFF161A1D),
    crashedShell: const Color(0xFF161A1D),
    crashedShade: const Color(0xFF161A1D),
    ringTrack: const Color(0xFF2A3035),
    accent: s.primary,
    alert: s.error,
    text: s.onSurface,
    muted: s.onSurfaceVariant,
  );
}
