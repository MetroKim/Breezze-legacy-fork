import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

/// User-selectable language preference. English is the default; translated
/// Material controls are available for these locales. Breezze's custom strings
/// still fall back to English until reviewed translations are shipped.
class BreezzeLanguage {
  final String code;
  final String name;
  const BreezzeLanguage(this.code, this.name);
}

const breezzeLanguages = <BreezzeLanguage>[
  BreezzeLanguage('en', 'English'),
  BreezzeLanguage('af', 'Afrikaans'),
  BreezzeLanguage('am', 'አማርኛ'),
  BreezzeLanguage('ar', 'العربية'),
  BreezzeLanguage('az', 'Azərbaycanca'),
  BreezzeLanguage('be', 'Беларуская'),
  BreezzeLanguage('bg', 'Български'),
  BreezzeLanguage('bn', 'বাংলা'),
  BreezzeLanguage('bs', 'Bosanski'),
  BreezzeLanguage('ca', 'Català'),
  BreezzeLanguage('cs', 'Čeština'),
  BreezzeLanguage('cy', 'Cymraeg'),
  BreezzeLanguage('da', 'Dansk'),
  BreezzeLanguage('de', 'Deutsch'),
  BreezzeLanguage('el', 'Ελληνικά'),
  BreezzeLanguage('es', 'Español'),
  BreezzeLanguage('et', 'Eesti'),
  BreezzeLanguage('eu', 'Euskara'),
  BreezzeLanguage('fa', 'فارسی'),
  BreezzeLanguage('fi', 'Suomi'),
  BreezzeLanguage('fil', 'Filipino'),
  BreezzeLanguage('fr', 'Français'),
  BreezzeLanguage('gl', 'Galego'),
  BreezzeLanguage('gu', 'ગુજરાતી'),
  BreezzeLanguage('he', 'עברית'),
  BreezzeLanguage('hi', 'हिन्दी'),
  BreezzeLanguage('hr', 'Hrvatski'),
  BreezzeLanguage('hu', 'Magyar'),
  BreezzeLanguage('hy', 'Հայերեն'),
  BreezzeLanguage('id', 'Bahasa Indonesia'),
  BreezzeLanguage('is', 'Íslenska'),
  BreezzeLanguage('it', 'Italiano'),
  BreezzeLanguage('ja', '日本語'),
  BreezzeLanguage('ka', 'ქართული'),
  BreezzeLanguage('kk', 'Қазақша'),
  BreezzeLanguage('km', 'ខ្មែរ'),
  BreezzeLanguage('kn', 'ಕನ್ನಡ'),
  BreezzeLanguage('ko', '한국어'),
  BreezzeLanguage('lo', 'ລາວ'),
  BreezzeLanguage('lt', 'Lietuvių'),
  BreezzeLanguage('lv', 'Latviešu'),
  BreezzeLanguage('mk', 'Македонски'),
  BreezzeLanguage('ml', 'മലയാളം'),
  BreezzeLanguage('mn', 'Монгол'),
  BreezzeLanguage('mr', 'मराठी'),
  BreezzeLanguage('ms', 'Bahasa Melayu'),
  BreezzeLanguage('my', 'မြန်မာ'),
  BreezzeLanguage('nb', 'Norsk bokmål'),
  BreezzeLanguage('ne', 'नेपाली'),
  BreezzeLanguage('nl', 'Nederlands'),
  BreezzeLanguage('pa', 'ਪੰਜਾਬੀ'),
  BreezzeLanguage('pl', 'Polski'),
  BreezzeLanguage('ps', 'پښتو'),
  BreezzeLanguage('pt', 'Português'),
  BreezzeLanguage('ro', 'Română'),
  BreezzeLanguage('ru', 'Русский'),
  BreezzeLanguage('si', 'සිංහල'),
  BreezzeLanguage('sk', 'Slovenčina'),
  BreezzeLanguage('sl', 'Slovenščina'),
  BreezzeLanguage('sq', 'Shqip'),
  BreezzeLanguage('sr', 'Српски'),
  BreezzeLanguage('sv', 'Svenska'),
  BreezzeLanguage('sw', 'Kiswahili'),
  BreezzeLanguage('ta', 'தமிழ்'),
  BreezzeLanguage('te', 'తెలుగు'),
  BreezzeLanguage('th', 'ไทย'),
  BreezzeLanguage('tr', 'Türkçe'),
  BreezzeLanguage('uk', 'Українська'),
  BreezzeLanguage('ur', 'اردو'),
  BreezzeLanguage('uz', 'Oʻzbekcha'),
  BreezzeLanguage('vi', 'Tiếng Việt'),
  BreezzeLanguage('zh', '中文'),
  BreezzeLanguage('zu', 'isiZulu'),
];

final breezzeSupportedLocales = <Locale>[
  for (final language in breezzeLanguages) Locale(language.code),
];

String breezzeLanguageName(String code) {
  for (final language in breezzeLanguages) {
    if (language.code == code) return language.name;
  }
  return 'English';
}

bool isBreezzeLanguage(String code) =>
    breezzeLanguages.any((language) => language.code == code);

final appLanguageProvider =
    AsyncNotifierProvider<AppLanguageController, String>(
  AppLanguageController.new,
);

class AppLanguageController extends AsyncNotifier<String> {
  static const _storage = FlutterSecureStorage();
  static const _key = 'breezze.app_language';

  @override
  Future<String> build() async {
    // Prefer the account's Supabase preference when signed in.
    // Offline fallback uses the device's last saved choice (English by default).
    final user = supa.Supabase.instance.client.auth.currentUser;
    if (user != null) {
      try {
        final data = await supa.Supabase.instance.client
            .from('profiles')
            .select('language')
            .eq('id', user.id)
            .maybeSingle();
        final remote = data?['language'] as String?;
        if (remote != null && isBreezzeLanguage(remote)) {
          await _storage.write(key: _key, value: remote);
          return remote;
        }
      } catch (_) {
        // Local setting works during an account-service outage.
      }
    }
    try {
      final local = await _storage.read(key: _key);
      return local != null && isBreezzeLanguage(local) ? local : 'en';
    } catch (_) {
      return 'en';
    }
  }

  Future<void> select(String code) async {
    if (!isBreezzeLanguage(code)) throw ArgumentError.value(code, 'code');
    final previous = state;
    state = const AsyncLoading<String>().copyWithPrevious(previous);
    try {
      final client = supa.Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user != null) {
        await client.from('profiles').upsert({
          'id': user.id,
          'language': code,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'id');
      }
      await _storage.write(key: _key, value: code);
      state = AsyncData(code);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}
