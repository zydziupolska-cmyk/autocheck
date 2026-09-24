import 'package:flutter/material.dart';

class AppTheme {
  // Kolory tła i powierzchni
  static const Color background = Color(0xFF090D14);
  static const Color surface = Color(0xFF131924);
  static const Color surfaceLight = Color(0xFF1D2636);
  static const Color border = Color(0xFF28344A);

  // Akcenty wyścigowe / telemetryczne
  static const Color cyan = Color(0xFF00E5FF);
  static const Color blue = Color(0xFF2979FF);
  static const Color orange = Color(0xFFFF9100);
  static const Color yellow = Color(0xFFFFD600);
  static const Color red = Color(0xFFFF1744);
  static const Color green = Color(0xFF00E676);
  static const Color purple = Color(0xFFD500F9);

  // Tekst
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: blue,
        surface: surface,
        error: red,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: border, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: cyan,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
