import 'package:flutter/material.dart';

/// Motyw Dynomic Diag.
///
/// Zasady: grafitowe, płaskie powierzchnie z cienką linią zamiast poświat i gradientów,
/// jeden kolor marki ([accent]) dla akcji i zaznaczeń, a kolory statusu
/// ([ok], [warn], [fault], [info]) wyłącznie tam, gdzie coś znaczą. Liczby w stałej
/// szerokości cyfr, żeby odczyty nie „skakały”.
class AppTheme {
  // Czerwień Dynomic (dynomic.pro) — przyciski, zaznaczenia, linia doładowania
  static const Color accent = Color(0xFFE51C1C);
  static const Color onAccent = Color(0xFFFFFFFF);

  // Powierzchnie
  static const Color background = Color(0xFF0F1113);
  static const Color surface = Color(0xFF16191C);
  static const Color surfaceLight = Color(0xFF1E2226);
  static const Color border = Color(0xFF2A2F35);

  // Status
  static const Color ok = Color(0xFF46A758);
  static const Color warn = Color(0xFFE2B340);
  static const Color fault = Color(0xFFF2555A);
  static const Color info = Color(0xFF5B8DEF);

  // Tekst
  static const Color textPrimary = Color(0xFFECEDEE);
  static const Color textSecondary = Color(0xFFA3A8AF);
  static const Color textMuted = Color(0xFF6B7178);

  static const double radius = 8;
  static const double radiusSmall = 6;

  /// Cyfry o stałej szerokości — do wszystkich odczytów liczbowych.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static const TextStyle label = TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500);
  static const TextStyle sectionTitle = TextStyle(color: textPrimary, fontSize: 15, fontWeight: FontWeight.w600);
  static const TextStyle body = TextStyle(color: textPrimary, fontSize: 14, height: 1.4);
  static const TextStyle caption = TextStyle(color: textMuted, fontSize: 12, height: 1.35);
  static const TextStyle readout = TextStyle(
    color: textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    fontFeatures: tabular,
    letterSpacing: -0.3,
  );

  static ThemeData get darkTheme {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      splashFactory: InkSparkle.splashFactory,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: onAccent,
        secondary: info,
        surface: surface,
        onSurface: textPrimary,
        error: fault,
        outline: border,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        iconTheme: IconThemeData(color: textSecondary),
        actionsIconTheme: IconThemeData(color: textSecondary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withAlpha(36),
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 11,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? textPrimary : textMuted,
            )),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              size: 22,
              color: s.contains(WidgetState.selected) ? accent : textMuted,
            )),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: surfaceLight,
          disabledForegroundColor: textMuted,
          elevation: 0,
          shape: shape,
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border),
          shape: shape,
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent, shape: shape),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(shape),
          side: const WidgetStatePropertyAll(BorderSide(color: border)),
          foregroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? textPrimary : textSecondary),
          backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? surfaceLight : Colors.transparent),
          iconColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? accent : textMuted),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: surfaceLight,
        side: const BorderSide(color: border),
        shape: shape,
        labelStyle: const TextStyle(color: textPrimary, fontSize: 12),
        checkmarkColor: accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        labelStyle: const TextStyle(color: textSecondary),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: const BorderSide(color: accent),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : textMuted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : surfaceLight),
        trackOutlineColor: const WidgetStatePropertyAll(border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(onAccent),
        side: const BorderSide(color: textMuted, width: 1.5),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent, linearTrackColor: surfaceLight),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: textSecondary,
        collapsedIconColor: textMuted,
        shape: Border(),
        collapsedShape: Border(),
      ),
      listTileTheme: const ListTileThemeData(iconColor: textSecondary),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceLight,
        contentTextStyle: const TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      badgeTheme: const BadgeThemeData(backgroundColor: fault, textColor: Colors.white),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    );
  }
}
