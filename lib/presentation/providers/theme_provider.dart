import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemePalette {
  classicBlue,
  emeraldGreen,
  royalPurple,
  oceanicCyan,
  sunsetCoral,
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

final themePaletteProvider =
    StateNotifierProvider<ThemePaletteNotifier, ThemePalette>((ref) {
  return ThemePaletteNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.dark) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('theme_mode') ?? 'dark';
    state = ThemeMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ThemeMode.dark,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
  }
}

class ThemePaletteNotifier extends StateNotifier<ThemePalette> {
  ThemePaletteNotifier() : super(ThemePalette.classicBlue) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('theme_palette') ?? 'classicBlue';
    state = ThemePalette.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ThemePalette.classicBlue,
    );
  }

  Future<void> setPalette(ThemePalette palette) async {
    state = palette;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_palette', palette.name);
  }
}
