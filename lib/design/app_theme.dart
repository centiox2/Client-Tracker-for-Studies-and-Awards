import 'package:flutter/material.dart';

/// Design system for S&A Hub: "Clarity".
///
/// Calm, light-first and data-focused: white cards on a soft grey page, the
/// Studies and Awards navy as the one accent (the logo's gold in dark mode),
/// an orange/blue pair for data and
/// plain status colours. The rules every screen follows:
///
///  1. **Numbers first.** The key figure on a card is the biggest thing on
///     it; labels are small and grey. Numbers use tabular figures ([Dt.tab]).
///  2. **One accent.** [Clarity.accent] is the only brand colour: the
///     primary button, the active menu item, links and simple meters.
///  3. **Data colours mean data.** Orange is always new clients, blue is
///     always existing clients — never decoration.
///  4. **Status is spelled out.** A coloured status always has a word too
///     ([StatusPill]).
///  5. **Empty is not zero.** A day not yet entered shows "—".
///  6. **Quiet chrome.** 1px borders, no shadows, no gradients.
abstract final class Dt {
  // ---- Radius -------------------------------------------------------------
  static const double rSm = 8; // buttons, inputs, menu items
  static const double rMd = 12; // cards
  static const double rLg = 12; // dialogs
  static const double rTag = 4; // small tags, keyboard hints
  static const double rPill = 999; // pills and chips

  // ---- Spacing (4px grid) -------------------------------------------------
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s44 = 44;

  /// Gap between cards.
  static const double gap = 16;

  /// Max width for centered reading content.
  static const double contentMaxWidth = 1240;

  /// The company behind the app, shown beside the logo.
  static const String companyName = 'Studies and Awards Limited';

  /// The short form in the sidebar.
  static const String companyShort = 'Studies and Awards Ltd';

  /// The app's name, everywhere people see it.
  static const String appName = 'S&A Hub';

  /// The "sa" logo on its own light square.
  static const String logoAsset = 'assets/branding/logo-square.png';

  /// The typeface (bundled).
  static const String font = 'Inter';

  // ---- Brand ----------------------------------------------------------------

  /// Studies and Awards Limited navy and gold, from the logo (for the logo
  /// and exported documents; screens use [Clarity.accent]).
  static const Color brandNavy = Color(0xFF001A45);
  static const Color brandGold = Color(0xFFFBBA00);

  /// The accent: the brand navy on light, the brand gold on dark.
  static Color brand(Brightness b) => Clarity.forBrightness(b).accent;

  /// Text and icons on [brand].
  static Color onBrand(Brightness b) => Clarity.forBrightness(b).onAccent;

  // ---- Data colours ---------------------------------------------------------

  /// New clients (orange).
  static Color newGreen(Brightness b) => Clarity.forBrightness(b).seriesNew;
  static Color newGreenBright(Brightness b) => newGreen(b);

  /// Existing clients (blue).
  static Color existingBlue(Brightness b) =>
      Clarity.forBrightness(b).seriesExisting;
  static Color existingBlueBright(Brightness b) => existingBlue(b);

  /// Positive status text ("Entered", "Active").
  static Color statusGreen(Brightness b) => Clarity.forBrightness(b).positiveFg;

  // ---- Typography helpers ---------------------------------------------------

  static const List<String> _monoFallback = [
    'Consolas',
    'Cascadia Mono',
    'Menlo',
    'DejaVu Sans Mono',
    'monospace',
  ];

  /// Segmented buttons on a phone: tighter, so several segments fit.
  static const ButtonStyle phoneSegments = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
  );

  /// Monospace with tabular figures (codes, references).
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

  /// Tabular figures on any style, so columns of numbers line up.
  static TextStyle tab(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  /// Labels, captions, dates, empty cells.
  static Color textMuted(ThemeData theme) => Clarity.of(theme).textMuted;

  /// The faintest text (placeholders, disabled).
  static Color textFaint(ThemeData theme) =>
      Clarity.of(theme).textMuted.withValues(alpha: 0.75);
}

/// The Clarity colour tokens, light and dark (see the design kit's
/// tokens.css). Read with `Clarity.of(Theme.of(context))` or
/// `context.clarity`.
@immutable
class Clarity extends ThemeExtension<Clarity> {
  const Clarity({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.borderSubtle,
    required this.borderStrong,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.onAccent,
    required this.seriesNew,
    required this.seriesExisting,
    required this.seriesThird,
    required this.seriesFourth,
    required this.track,
    required this.gridline,
    required this.positiveBg,
    required this.positiveFg,
    required this.warningBg,
    required this.warningFg,
    required this.noticeBg,
    required this.noticeBorder,
    required this.noticeFg,
    required this.noticeBtnBorder,
    required this.neutralBg,
    required this.neutralFg,
    required this.negativeFg,
    required this.focus,
    required this.brandGold,
  });

  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color borderSubtle;
  final Color borderStrong;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentHover;
  final Color accentSoft;
  final Color onAccent;
  final Color seriesNew;
  final Color seriesExisting;
  final Color seriesThird;
  final Color seriesFourth;
  final Color track;
  final Color gridline;
  final Color positiveBg;
  final Color positiveFg;
  final Color warningBg;
  final Color warningFg;
  final Color noticeBg;
  final Color noticeBorder;
  final Color noticeFg;
  final Color noticeBtnBorder;
  final Color neutralBg;
  final Color neutralFg;
  final Color negativeFg;

  /// The focus ring.
  final Color focus;

  /// The logo's gold (snackbar actions; the dark theme's accent).
  final Color brandGold;

  static const light = Clarity(
    bg: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    border: Color(0xFFE4E7EC),
    borderSubtle: Color(0xFFEEF0F3),
    borderStrong: Color(0xFFD0D5DD),
    text: Color(0xFF0F172A),
    textSecondary: Color(0xFF344054),
    textMuted: Color(0xFF5B6474),
    // Studies and Awards navy (the logo's), for the accent.
    accent: Color(0xFF001A45),
    accentHover: Color(0xFF0B2E6B),
    accentSoft: Color(0xFFEAEFF7),
    onAccent: Color(0xFFFFFFFF),
    seriesNew: Color(0xFFE8833A),
    seriesExisting: Color(0xFF3B5BDB),
    seriesThird: Color(0xFF0F9F8F),
    seriesFourth: Color(0xFF8B5CF6),
    track: Color(0xFFEEF0F3),
    gridline: Color(0xFFF0F2F5),
    positiveBg: Color(0xFFECFDF3),
    positiveFg: Color(0xFF166534),
    warningBg: Color(0xFFFFF4E5),
    warningFg: Color(0xFF8A4B08),
    noticeBg: Color(0xFFFFF8EC),
    noticeBorder: Color(0xFFF3D9B1),
    noticeFg: Color(0xFF7A4A06),
    noticeBtnBorder: Color(0xFFE4C48E),
    neutralBg: Color(0xFFF2F4F7),
    neutralFg: Color(0xFF475467),
    negativeFg: Color(0xFFB42318),
    focus: Color(0x40001A45),
    brandGold: Color(0xFFFBBA00),
  );

  static const dark = Clarity(
    bg: Color(0xFF0E1116),
    surface: Color(0xFF161B22),
    surfaceRaised: Color(0xFF1C2230),
    border: Color(0xFF2A3140),
    borderSubtle: Color(0xFF222936),
    borderStrong: Color(0xFF3A4354),
    text: Color(0xFFE6EAF0),
    textSecondary: Color(0xFFC3CAD5),
    textMuted: Color(0xFF9AA4B2),
    // Studies and Awards gold on dark (navy would vanish), navy text on it.
    accent: Color(0xFFFBBA00),
    accentHover: Color(0xFFFFD24D),
    accentSoft: Color(0x24FBBA00),
    onAccent: Color(0xFF001A45),
    seriesNew: Color(0xFFF0A060),
    seriesExisting: Color(0xFF6F8BFF),
    seriesThird: Color(0xFF3CC8B4),
    seriesFourth: Color(0xFFA78BFA),
    track: Color(0xFF232A37),
    gridline: Color(0xFF1E2430),
    positiveBg: Color(0xFF12301F),
    positiveFg: Color(0xFF7EE2A8),
    warningBg: Color(0xFF3A2A10),
    warningFg: Color(0xFFF5C77A),
    noticeBg: Color(0xFF2A2112),
    noticeBorder: Color(0xFF4A3A1C),
    noticeFg: Color(0xFFF5C77A),
    noticeBtnBorder: Color(0xFF5C4824),
    neutralBg: Color(0xFF222A36),
    neutralFg: Color(0xFFB8C1CE),
    negativeFg: Color(0xFFFF8A80),
    focus: Color(0x59FBBA00),
    brandGold: Color(0xFFFBBA00),
  );

  static Clarity forBrightness(Brightness b) =>
      b == Brightness.light ? light : dark;

  static Clarity of(ThemeData theme) =>
      theme.extension<Clarity>() ?? forBrightness(theme.brightness);

  @override
  Clarity copyWith() => this;

  @override
  Clarity lerp(ThemeExtension<Clarity>? other, double t) {
    if (other is! Clarity) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return Clarity(
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      border: c(border, other.border),
      borderSubtle: c(borderSubtle, other.borderSubtle),
      borderStrong: c(borderStrong, other.borderStrong),
      text: c(text, other.text),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      accent: c(accent, other.accent),
      accentHover: c(accentHover, other.accentHover),
      accentSoft: c(accentSoft, other.accentSoft),
      onAccent: c(onAccent, other.onAccent),
      seriesNew: c(seriesNew, other.seriesNew),
      seriesExisting: c(seriesExisting, other.seriesExisting),
      seriesThird: c(seriesThird, other.seriesThird),
      seriesFourth: c(seriesFourth, other.seriesFourth),
      track: c(track, other.track),
      gridline: c(gridline, other.gridline),
      positiveBg: c(positiveBg, other.positiveBg),
      positiveFg: c(positiveFg, other.positiveFg),
      warningBg: c(warningBg, other.warningBg),
      warningFg: c(warningFg, other.warningFg),
      noticeBg: c(noticeBg, other.noticeBg),
      noticeBorder: c(noticeBorder, other.noticeBorder),
      noticeFg: c(noticeFg, other.noticeFg),
      noticeBtnBorder: c(noticeBtnBorder, other.noticeBtnBorder),
      neutralBg: c(neutralBg, other.neutralBg),
      neutralFg: c(neutralFg, other.neutralFg),
      negativeFg: c(negativeFg, other.negativeFg),
      focus: c(focus, other.focus),
      brandGold: c(brandGold, other.brandGold),
    );
  }
}

extension ClarityContext on BuildContext {
  /// The Clarity tokens for the current theme.
  Clarity get clarity => Clarity.of(Theme.of(this));
}

/// A small coloured dot before a label.
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

/// Section label: 11px, 600, UPPERCASE in use, lightly tracked, muted.
TextStyle microLabel(ThemeData theme, {Color? color}) => TextStyle(
  fontFamily: Dt.font,
  fontSize: 11,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.66,
  color: color ?? Dt.textMuted(theme),
);

/// Builds the Clarity theme for [brightness].
ThemeData buildAppTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final c = Clarity.forBrightness(brightness);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.accent,
    secondary: c.textSecondary,
    onSecondary: c.surface,
    secondaryContainer: c.neutralBg,
    onSecondaryContainer: c.text,
    tertiary: c.seriesNew,
    onTertiary: c.surface,
    tertiaryContainer: c.neutralBg,
    onTertiaryContainer: c.text,
    error: c.negativeFg,
    onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF2A0A05),
    errorContainer: light ? const Color(0xFFFEF3F2) : const Color(0xFF3A1714),
    onErrorContainer: c.negativeFg,
    // The page; cards sit on surfaceContainerLow.
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.textMuted,
    outline: c.border,
    outlineVariant: c.borderSubtle,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: c.text,
    onInverseSurface: c.surface,
    inversePrimary: c.accent,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.neutralBg,
    surfaceContainerHighest: c.neutralBg,
  );

  // The sizes below build on the styles that already carry Inter and the
  // text colours (built on the plain Material ones they'd lose both).
  final baseText = (light ? ThemeData.light() : ThemeData.dark()).textTheme
      .apply(
        bodyColor: c.text,
        displayColor: c.text,
        fontFamily: Dt.font,
        fontFamilyFallback: const [
          'Segoe UI',
          'Roboto',
          'Helvetica Neue',
          'Arial',
          'sans-serif',
        ],
      );
  final textTheme = baseText.copyWith(
    displayLarge: baseText.displayLarge?.copyWith(
      fontSize: 56,
      fontWeight: FontWeight.w700,
      height: 1.05,
      letterSpacing: -1.1,
    ),
    displayMedium: baseText.displayMedium?.copyWith(
      fontSize: 44,
      fontWeight: FontWeight.w700,
      height: 1.05,
      letterSpacing: -0.9,
    ),
    // KPI number.
    displaySmall: baseText.displaySmall?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.64,
    ),
    headlineLarge: baseText.headlineLarge?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.15,
      letterSpacing: -0.64,
    ),
    // Page title.
    headlineMedium: baseText.headlineMedium?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.2,
      letterSpacing: -0.56,
    ),
    headlineSmall: baseText.headlineSmall?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.2,
      letterSpacing: -0.3,
    ),
    titleLarge: baseText.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    // Card title.
    titleMedium: baseText.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
    ),
    titleSmall: baseText.titleSmall?.copyWith(
      letterSpacing: 0,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: baseText.bodyLarge?.copyWith(
      letterSpacing: 0,
      fontSize: 15,
      height: 1.45,
    ),
    bodyMedium: baseText.bodyMedium?.copyWith(
      letterSpacing: 0,
      fontSize: 14,
      height: 1.45,
    ),
    bodySmall: baseText.bodySmall?.copyWith(
      letterSpacing: 0,
      fontSize: 12,
      height: 1.4,
      color: c.textMuted,
    ),
    labelLarge: baseText.labelLarge?.copyWith(
      letterSpacing: 0,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: baseText.labelMedium?.copyWith(
      letterSpacing: 0,
      fontSize: 13,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: baseText.labelSmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
  );

  OutlineInputBorder fieldBorder({Color? color, double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
        borderSide: BorderSide(color: color ?? c.borderStrong, width: width),
      );

  const buttonText = TextStyle(
    fontFamily: Dt.font,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Dt.rSm),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: Dt.font,
    colorScheme: scheme,
    textTheme: textTheme,
    extensions: [c],
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.surface,
    splashFactory: NoSplash.splashFactory,
    hoverColor: c.text.withValues(alpha: 0.04),
    highlightColor: c.text.withValues(alpha: 0.06),
    focusColor: c.focus,
    splashColor: Colors.transparent,

    cardTheme: CardThemeData(
      elevation: 0,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rMd),
        side: BorderSide(color: c.border),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rLg),
        side: BorderSide(color: c.border),
      ),
      titleTextStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: c.text,
      ),
      contentTextStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 14,
        height: 1.45,
        color: c.textSecondary,
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      dragHandleColor: c.borderStrong,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Dt.rLg)),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.surface,
      hintStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 14,
        color: c.textMuted,
      ),
      labelStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 14,
        color: c.textMuted,
      ),
      // Grey, in the accent only while the field is being typed in.
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          fontFamily: Dt.font,
          fontSize: 14,
          color: states.contains(WidgetState.error)
              ? c.negativeFg
              : states.contains(WidgetState.focused)
              ? c.accent
              : c.textMuted,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: fieldBorder(),
      enabledBorder: fieldBorder(color: c.border),
      focusedBorder: fieldBorder(color: c.accent, width: 1.5),
      errorBorder: fieldBorder(color: c.negativeFg),
      focusedErrorBorder: fieldBorder(color: c.negativeFg, width: 1.5),
      disabledBorder: fieldBorder(color: c.borderSubtle),
    ),

    // The main action: one per screen.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? c.neutralBg
              : s.contains(WidgetState.hovered) ||
                    s.contains(WidgetState.pressed)
              ? c.accentHover
              : c.accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? c.textMuted : c.onAccent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: const WidgetStatePropertyAll(buttonText),
        iconSize: const WidgetStatePropertyAll(16),
      ),
    ),
    // Secondary: Export, date pickers, filters.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? c.neutralBg : c.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? c.textMuted : c.text,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.disabled) ? c.border : c.borderStrong,
          ),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: Dt.font,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        iconSize: const WidgetStatePropertyAll(16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: buttonShape,
        textStyle: const TextStyle(
          fontFamily: Dt.font,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.textMuted,
        iconSize: 18,
        minimumSize: const Size(40, 40),
        shape: buttonShape,
      ),
    ),

    // A soft pill group: a grey track, the chosen option a white chip.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll(0),
        side: WidgetStatePropertyAll(BorderSide(color: c.neutralBg, width: 3)),
        shape: WidgetStatePropertyAll(buttonShape),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.surface : c.neutralBg,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.text : c.textSecondary,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        textStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: Dt.font,
            fontSize: 14,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.accentSoft,
      side: BorderSide(color: c.border),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: c.textSecondary,
      ),
      secondaryLabelStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: c.accent,
      ),
      checkmarkColor: c.accent,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(c.onAccent),
      side: BorderSide(color: c.borderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : c.borderStrong,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.track,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong,
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong,
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: Dt.font,
          fontSize: 11.5,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? c.accent : c.textMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 20,
          color: s.contains(WidgetState.selected) ? c.accent : c.textMuted,
        ),
      ),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.track,
      circularTrackColor: Colors.transparent,
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: c.text,
      ),
      iconTheme: IconThemeData(size: 20, color: c.textMuted),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: c.textMuted,
      selectedColor: c.accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: Dt.s12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
        side: BorderSide(color: c.border),
      ),
      textStyle: TextStyle(fontFamily: Dt.font, fontSize: 14, color: c.text),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surfaceRaised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
        shape: WidgetStatePropertyAll(buttonShape),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surfaceRaised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
      ),
    ),

    datePickerTheme: DatePickerThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rLg),
        side: BorderSide(color: c.border),
      ),
      headerBackgroundColor: c.surfaceRaised,
      headerForegroundColor: c.text,
      todayBorder: BorderSide(color: c.accent),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: c.text,
      contentTextStyle: TextStyle(
        fontFamily: Dt.font,
        fontSize: 14,
        color: c.surface,
      ),
      actionTextColor: c.brandGold,
      closeIconColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
    ),

    badgeTheme: BadgeThemeData(
      backgroundColor: c.accent,
      textColor: c.onAccent,
    ),

    dividerTheme: DividerThemeData(
      color: c.borderSubtle,
      thickness: 1,
      space: 1,
    ),

    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      thumbVisibility: const WidgetStatePropertyAll(true),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(c.borderStrong),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.text,
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
      textStyle: TextStyle(fontFamily: Dt.font, fontSize: 12, color: c.surface),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
