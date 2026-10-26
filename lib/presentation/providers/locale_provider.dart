import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/app_locale.dart';

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier();
});

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('en', 'US')) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('locale') ?? 'en';
    // Point 5: keep the context-free mirror in step, so notifications and
    // other services speak the same language as the UI.
    AppLocale.set(code);
    state = code == 'en' ? const Locale('en', 'US') : const Locale('fa', 'IR');
  }

  Future<void> setLocale(Locale locale) async {
    state = locale;
    AppLocale.set(locale.languageCode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', locale.languageCode);
  }

  void toggle() {
    if (state.languageCode == 'fa') {
      setLocale(const Locale('en', 'US'));
    } else {
      setLocale(const Locale('fa', 'IR'));
    }
  }
}
