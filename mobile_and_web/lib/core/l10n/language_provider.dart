import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

class AppLanguage {
  final String code;
  final String name;
  final String flag;
  final bool isRtl;

  const AppLanguage({
    required this.code,
    required this.name,
    required this.flag,
    this.isRtl = false,
  });
}

class LanguageProvider extends ChangeNotifier {
  static const String _prefLanguageKey = 'selected_language_code';

  static const List<AppLanguage> supportedLanguages = [
    AppLanguage(code: 'tr', name: 'Türkçe', flag: '🇹🇷'),
    AppLanguage(code: 'en', name: 'English', flag: '🇬🇧'),
    AppLanguage(code: 'de', name: 'Deutsch', flag: '🇩🇪'),
    AppLanguage(code: 'es', name: 'Español', flag: '🇪🇸'),
    AppLanguage(code: 'fr', name: 'Français', flag: '🇫🇷'),
    AppLanguage(code: 'ar', name: 'العربية', flag: '🇸🇦', isRtl: true),
    AppLanguage(code: 'ru', name: 'Русский', flag: '🇷🇺'),
    AppLanguage(code: 'id', name: 'Bahasa Indonesia', flag: '🇮🇩'),
    AppLanguage(code: 'pt', name: 'Português', flag: '🇵🇹'),
    AppLanguage(code: 'zh', name: '简体中文', flag: '🇨🇳'),
  ];

  Locale _locale = const Locale('tr');
  bool _initialized = false;

  Locale get locale => _locale;
  String get currentCode => _locale.languageCode;
  bool get isInitialized => _initialized;

  AppLanguage get currentLanguage {
    return supportedLanguages.firstWhere(
      (lang) => lang.code == currentCode,
      orElse: () => supportedLanguages.first,
    );
  }

  bool get isRtl => currentLanguage.isRtl;
  TextDirection get textDirection =>
      isRtl ? TextDirection.rtl : TextDirection.ltr;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString(_prefLanguageKey);

      if (savedCode != null && _isSupportedCode(savedCode)) {
        _locale = Locale(savedCode);
      } else {
        // Cihaz sistem dilini otomatik algıla
        final systemCode =
            PlatformDispatcher.instance.locale.languageCode.toLowerCase();
        if (_isSupportedCode(systemCode)) {
          _locale = Locale(systemCode);
        } else {
          // Desteklenenler arasında yoksa global standart olarak İngilizce aç
          _locale = const Locale('en');
        }
      }
    } catch (_) {
      _locale = const Locale('tr');
    }

    ApiClient.currentLanguage = _locale.languageCode;
    _initialized = true;
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    final cleanCode = code.toLowerCase().trim();
    if (!_isSupportedCode(cleanCode)) return;

    if (_locale.languageCode == cleanCode) return;

    _locale = Locale(cleanCode);
    ApiClient.currentLanguage = cleanCode;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLanguageKey, cleanCode);
    } catch (_) {}

    notifyListeners();
  }

  bool _isSupportedCode(String code) {
    return supportedLanguages.any((lang) => lang.code == code.toLowerCase());
  }
}

/// Tüm widget ağacından [LanguageProvider]'a kolay erişim sağlayan [InheritedNotifier].
class LanguageScope extends InheritedNotifier<LanguageProvider> {
  const LanguageScope({
    super.key,
    required LanguageProvider provider,
    required super.child,
  }) : super(notifier: provider);

  static LanguageProvider of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LanguageScope>();
    assert(scope != null, 'No LanguageScope found in context');
    return scope!.notifier!;
  }

  static LanguageProvider? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LanguageScope>();
    return scope?.notifier;
  }
}
