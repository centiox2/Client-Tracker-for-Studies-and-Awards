import 'package:flutter/material.dart';

/// Design system for Client Tracker.
///
/// Dark operational dashboard theme with compact navigation, slate panels,
/// restrained borders, and clear new/existing client colors.
///
/// The rules this file encodes — every screen must obey them:
///
///  1. **Quiet surfaces.** Structure comes from 1px outline rules and spacing,
///     not shadows. Cards and panels stay close to the page surface.
///  2. **One typeface.** Instrument Sans carries everything; numbers use
///     tabular figures ([Dt.tab]) so columns line up. Uppercase micro-labels
///     use [microLabel].
///  3. **A restrained color system.** Peach marks new-client data, periwinkle
///     marks existing-client data, and green is reserved for positive status.
///     Other content stays neutral; the company's navy (light theme) or
///     gold (dark theme) is reserved for primary actions and selection.
///  4. **Compact controls.** Fields and standard action buttons use a 6px
///     radius, panels use the shared 8px radius, and pill shapes are reserved
///     for chips and toggles.
///  5. **Numbers are data.** Large figures use tabular serif numerals; dense
///     date and count strings use tabular monospace helpers.
abstract final class Dt {
  // ---- Radius system ----------------------------------------------------
  static const double rSm = 6; // fields, inputs
  static const double rMd = 8; // tiles, panels, menus
  static const double rLg = 12; // cards, dialogs
  static const double rPill = 999; // chips and segmented controls

  // ---- 4px spacing grid -------------------------------------------------
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s44 = 44; // editorial gutter between columns

  /// Max width for centered reading content (dashboard, settings).
  static const double contentMaxWidth = 1240;

  /// The company behind the app, shown beside the logo.
  static const String companyName = 'Studies and Awards Limited';

  /// The "sa" logo on its own light square — readable on light and dark
  /// backgrounds alike (the navy letters alone vanish on the dark theme).
  static const String logoAsset = 'assets/branding/logo-square.png';

  // ---- Brand ---------------------------------------------------------------

  /// Studies and Awards Limited navy and gold, from the logo.
  static const Color brandNavy = Color(0xFF001A45);
  static const Color brandGold = Color(0xFFFBBA00);

  /// The brand colour for primary actions and selection: navy on the light
  /// theme, gold on the dark one (navy would vanish against near-black).
  static Color brand(Brightness b) =>
      b == Brightness.light ? brandNavy : brandGold;

  /// Text and icons drawn on [brand].
  static Color onBrand(Brightness b) =>
      b == Brightness.light ? Colors.white : brandNavy;

  // ---- Semantic data colors ---------------------------------------------

  /// "New clients" — the warm peach of the duotone pair.
  static Color newGreen(Brightness b) => b == Brightness.light
      ? const Color(0xFFB65C33) // deepened for contrast on paper
      : const Color(0xFFF29A70);

  /// A lighter tint of the peach used on filled chips/values in dark mode.
  static Color newGreenBright(Brightness b) =>
      b == Brightness.light ? const Color(0xFFB65C33) : const Color(0xFFFFB28E);

  /// "Existing clients" — the periwinkle of the duotone pair.
  static Color existingBlue(Brightness b) => b == Brightness.light
      ? const Color(0xFF4C6EA8) // deepened for contrast on paper
      : const Color(0xFFAEC4EC);

  /// A lighter tint of the periwinkle for filled values in dark mode.
  static Color existingBlueBright(Brightness b) =>
      b == Brightness.light ? const Color(0xFF4C6EA8) : const Color(0xFFC3D5F3);

  /// Positive/active status green (staff "Active" dot).
  static Color statusGreen(Brightness b) =>
      b == Brightness.light ? const Color(0xFF2F7D4F) : const Color(0xFF8FD19E);

  // ---- Typography helpers -----------------------------------------------

  static const List<String> _monoFallback = [
    'Consolas', // Windows
    'Cascadia Mono', // Windows 11
    'Menlo', // macOS
    'DejaVu Sans Mono', // Linux
    'monospace',
  ];

  /// Data text: monospace family + tabular figures so columns align.
  static TextStyle mono(
    BuildContext context, {
    double? size,
    FontWeight? weight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: _monoFallback,
      fontFeatures: const [FontFeature.tabularFigures()],
      fontSize: size,
      fontWeight: weight,
      color: color ?? scheme.onSurface,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// Tabular figures on any base style — columnar alignment without mono.
  static TextStyle tab(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  /// Muted text (third contrast level).
  static Color textMuted(ThemeData theme) =>
      theme.brightness == Brightness.light
      ? const Color(0xFF626A73)
      : const Color(0xFF9AA0A8);

  /// Faint text (fourth contrast level).
  static Color textFaint(ThemeData theme) =>
      theme.brightness == Brightness.light
      ? const Color(0xFF858D96)
      : const Color(0xFF6E747C);
}

/// The standard 6px meaning-dot used before uppercase micro-labels.
class MeaningDot extends StatelessWidget {
  const MeaningDot(this.color, {super.key, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Uppercase micro-label style ("cap" in the mockups): compact, medium weight,
/// lightly tracked, and muted.
TextStyle microLabel(ThemeData theme, {Color? color}) => TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.2,
  color: color ?? Dt.textMuted(theme),
);

/// Neutral application surfaces shared by both themes.
class _Palette {
  const _Palette({
    required this.bg,
    required this.panel,
    required this.panelStrong,
    required this.field,
    required this.fg,
    required this.secondary,
    required this.border,
    required this.borderStrong,
    required this.error,
  });

  final Color bg;
  final Color panel;
  final Color panelStrong;
  final Color field;
  final Color fg;
  final Color secondary;
  final Color border;
  final Color borderStrong;
  final Color error;

  static _Palette dark() => const _Palette(
    bg: Color(0xFF090A0C),
    panel: Color(0xFF111315),
    panelStrong: Color(0xFF1A1D20),
    field: Color(0xFF0C0E10),
    fg: Color(0xFFE7E9EC),
    secondary: Color(0xFF9AA0A8),
    border: Color(0xFF25282C),
    borderStrong: Color(0xFF34383D),
    error: Color(0xFFFF7777),
  );

  static _Palette light() => const _Palette(
    bg: Color(0xFFF4F5F7),
    panel: Color(0xFFFFFFFF),
    panelStrong: Color(0xFFEAEDF0),
    field: Color(0xFFFFFFFF),
    fg: Color(0xFF202328),
    secondary: Color(0xFF626A73),
    border: Color(0xFFE0E3E7),
    borderStrong: Color(0xFFC8CDD3),
    error: Color(0xFFB3361F),
  );
}

/// Builds the app theme for [brightness].
///
/// Same structure in both modes — "same structure, different values" — the
/// dark theme is the primary design (matches the mockups), light is its
/// warm-paper inversion.
ThemeData buildAppTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final p = light ? _Palette.light() : _Palette.dark();

  final brand = Dt.brand(brightness);
  final onBrand = Dt.onBrand(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: brand,
    onPrimary: onBrand,
    primaryContainer: p.panelStrong,
    onPrimaryContainer: p.fg,
    secondary: p.secondary,
    onSecondary: p.bg,
    secondaryContainer: p.panel,
    onSecondaryContainer: p.fg,
    tertiary: Dt.newGreen(brightness),
    onTertiary: p.bg,
    tertiaryContainer: p.panelStrong,
    onTertiaryContainer: p.fg,
    error: p.error,
    onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF2A0A05),
    errorContainer: light ? const Color(0xFFF6DED8) : const Color(0xFF2A1714),
    onErrorContainer: light ? const Color(0xFF7F2A18) : const Color(0xFFFFB4A8),
    surface: p.bg,
    onSurface: p.fg,
    onSurfaceVariant: p.secondary,
    outline: p.borderStrong,
    outlineVariant: p.border,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: p.fg,
    onInverseSurface: p.bg,
    inversePrimary: brand,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.panel,
    surfaceContainer: p.panel,
    surfaceContainerHigh: p.panelStrong,
    surfaceContainerHighest: p.panelStrong,
  );

  final baseText = (light ? ThemeData.light() : ThemeData.dark()).textTheme;
  final textTheme = baseText
      .apply(
        bodyColor: p.fg,
        displayColor: p.fg,
        fontFamily: 'Instrument Sans',
        fontFamilyFallback: const [
          'Segoe UI',
          'Helvetica Neue',
          'Arial',
          'sans-serif',
        ],
      )
      .copyWith(
        displayLarge: baseText.displayLarge?.copyWith(
          fontSize: 60,
          height: 1.05,
          letterSpacing: -0.5,
        ),
        displayMedium: baseText.displayMedium?.copyWith(
          fontSize: 48,
          height: 1.05,
          letterSpacing: -0.5,
        ),
        headlineLarge: baseText.headlineLarge?.copyWith(
          fontSize: 38,
          height: 1.1,
          letterSpacing: -0.3,
        ),
        headlineMedium: baseText.headlineMedium?.copyWith(
          fontSize: 30,
          height: 1.15,
          letterSpacing: -0.3,
        ),
        headlineSmall: baseText.headlineSmall?.copyWith(
          fontSize: 24,
          height: 1.15,
          letterSpacing: -0.2,
        ),
        titleLarge: baseText.titleLarge?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: baseText.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        titleSmall: baseText.titleSmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 15, height: 1.5),
        bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 13.5, height: 1.5),
        bodySmall: baseText.bodySmall?.copyWith(fontSize: 12, height: 1.45),
        labelLarge: baseText.labelLarge?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        labelMedium: baseText.labelMedium?.copyWith(fontSize: 12.5),
        labelSmall: baseText.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      );

  BorderSide thin() => BorderSide(color: p.border);
  OutlineInputBorder fieldBorder({Color? color, double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
        borderSide: BorderSide(color: color ?? p.borderStrong, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: p.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.fg.withValues(alpha: 0.05),
    splashColor: Colors.transparent,

    // Compact neutral panels with visible edges in both themes.
    cardTheme: CardThemeData(
      elevation: 0,
      color: p.bg,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rMd),
        side: thin(),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rLg),
        side: BorderSide(color: p.borderStrong),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 20,
        color: p.fg,
      ),
      contentTextStyle: TextStyle(
        fontSize: 13.5,
        height: 1.5,
        color: p.secondary,
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.field,
      hintStyle: TextStyle(
        fontSize: 13.5,
        color: p.secondary.withValues(alpha: 0.8),
      ),
      labelStyle: TextStyle(fontSize: 13.5, color: p.secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: fieldBorder(),
      enabledBorder: fieldBorder(),
      focusedBorder: fieldBorder(color: brand, width: 1.4),
      errorBorder: fieldBorder(color: p.error),
      focusedErrorBorder: fieldBorder(color: p.error, width: 1.2),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: onBrand,
        elevation: 0,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dt.rSm),
        ),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        iconSize: 17,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.fg,
        elevation: 0,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: BorderSide(color: p.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dt.rSm),
        ),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        iconSize: 17,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.fg,
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dt.rSm),
        ),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.secondary,
        iconSize: 18,
        shape: const CircleBorder(),
      ),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll(0),
        side: WidgetStatePropertyAll(BorderSide(color: p.borderStrong)),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? brand
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? onBrand : p.secondary,
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bg,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? p.fg : p.secondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? brand : p.secondary,
        ),
      ),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(color: brand),

    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: p.fg,
      ),
      iconTheme: IconThemeData(size: 20, color: p.secondary),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: p.secondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: Dt.s12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: p.panelStrong,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rMd),
        side: BorderSide(color: p.borderStrong),
      ),
      textStyle: TextStyle(fontSize: 13.5, color: p.fg),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: p.fg,
      contentTextStyle: TextStyle(fontSize: 13, color: p.bg),
      shape: const StadiumBorder(),
    ),

    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),

    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(6),
      thumbVisibility: WidgetStatePropertyAll(true),
      radius: Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.borderStrong),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.fg,
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
      textStyle: TextStyle(fontSize: 11.5, color: p.bg),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
