/// Breezze-owned copy with reviewed, minimal navigation translations.
/// Other labels deliberately fall back to English until localized resources
/// are ready. This is distinct from Flutter's Material control translations.
const _copy = <String, Map<String, String>>{
  'sw': {
    'Home': 'Nyumbani', 'Browse': 'Gundua', 'Library': 'Maktaba',
    'Search': 'Tafuta', 'Settings': 'Mipangilio',
    'Account': 'Akaunti', 'App language': 'Lugha ya programu',
    'Made for You': 'Kwa ajili yako',
    'From Artists You Follow': 'Kutoka kwa wasanii unaowafuata',
  },
  'fr': {
    'Home': 'Accueil', 'Browse': 'Explorer', 'Library': 'Bibliothèque',
    'Search': 'Rechercher', 'Settings': 'Paramètres',
    'Account': 'Compte', 'App language': "Langue de l’application",
    'Made for You': 'Pour vous',
    'From Artists You Follow': 'Artistes que vous suivez',
  },
  'es': {
    'Home': 'Inicio', 'Browse': 'Explorar', 'Library': 'Biblioteca',
    'Search': 'Buscar', 'Settings': 'Configuración',
    'Account': 'Cuenta', 'App language': 'Idioma de la aplicación',
    'Made for You': 'Hecho para ti',
    'From Artists You Follow': 'De artistas que sigues',
  },
  'pt': {
    'Home': 'Início', 'Browse': 'Explorar', 'Library': 'Biblioteca',
    'Search': 'Pesquisar', 'Settings': 'Definições',
    'Account': 'Conta', 'App language': 'Idioma da aplicação',
    'Made for You': 'Feito para si',
    'From Artists You Follow': 'Dos artistas que segue',
  },
  'de': {
    'Home': 'Start', 'Browse': 'Entdecken', 'Library': 'Mediathek',
    'Search': 'Suchen', 'Settings': 'Einstellungen',
    'Account': 'Konto', 'App language': 'App-Sprache',
    'Made for You': 'Für dich',
    'From Artists You Follow': 'Von Künstlern, denen du folgst',
  },
  'it': {
    'Home': 'Home', 'Browse': 'Esplora', 'Library': 'Libreria',
    'Search': 'Cerca', 'Settings': 'Impostazioni',
    'Account': 'Account', 'App language': "Lingua dell’app",
    'Made for You': 'Per te',
    'From Artists You Follow': 'Dagli artisti che segui',
  },
  'ar': {
    'Home': 'الرئيسية', 'Browse': 'استكشاف', 'Library': 'مكتبتي',
    'Search': 'بحث', 'Settings': 'الإعدادات',
    'Account': 'الحساب', 'App language': 'لغة التطبيق',
    'Made for You': 'من أجلك',
    'From Artists You Follow': 'من الفنانين الذين تتابعهم',
  },
  'hi': {
    'Home': 'होम', 'Browse': 'खोजें', 'Library': 'लाइब्रेरी',
    'Search': 'खोज', 'Settings': 'सेटिंग्स',
    'Account': 'खाता', 'App language': 'ऐप की भाषा',
    'Made for You': 'आपके लिए',
    'From Artists You Follow': 'आपके फ़ॉलो किए कलाकारों से',
  },
  'ru': {
    'Home': 'Главная', 'Browse': 'Обзор', 'Library': 'Медиатека',
    'Search': 'Поиск', 'Settings': 'Настройки',
    'Account': 'Аккаунт', 'App language': 'Язык приложения',
    'Made for You': 'Для вас',
    'From Artists You Follow': 'От ваших любимых исполнителей',
  },
  'zh': {
    'Home': '主页', 'Browse': '浏览', 'Library': '资料库',
    'Search': '搜索', 'Settings': '设置',
    'Account': '账户', 'App language': '应用语言',
    'Made for You': '为你推荐',
    'From Artists You Follow': '来自你关注的艺人',
  },
  'ja': {
    'Home': 'ホーム', 'Browse': '見つける', 'Library': 'ライブラリ',
    'Search': '検索', 'Settings': '設定',
    'Account': 'アカウント', 'App language': 'アプリの言語',
    'Made for You': 'あなたへのおすすめ',
    'From Artists You Follow': 'フォロー中のアーティストから',
  },
  'ko': {
    'Home': '홈', 'Browse': '둘러보기', 'Library': '보관함',
    'Search': '검색', 'Settings': '설정',
    'Account': '계정', 'App language': '앱 언어',
    'Made for You': '회원님을 위한 추천',
    'From Artists You Follow': '팔로우한 아티스트의 음악',
  },
  'id': {
    'Home': 'Beranda', 'Browse': 'Jelajahi', 'Library': 'Koleksi',
    'Search': 'Cari', 'Settings': 'Pengaturan',
    'Account': 'Akun', 'App language': 'Bahasa aplikasi',
    'Made for You': 'Untuk Anda',
    'From Artists You Follow': 'Dari artis yang Anda ikuti',
  },
  'tr': {
    'Home': 'Ana Sayfa', 'Browse': 'Keşfet', 'Library': 'Kitaplık',
    'Search': 'Ara', 'Settings': 'Ayarlar',
    'Account': 'Hesap', 'App language': 'Uygulama dili',
    'Made for You': 'Senin İçin',
    'From Artists You Follow': 'Takip Ettiğin Sanatçılardan',
  },
};

String breezzeText(String language, String english) =>
    _copy[language]?[english] ?? english;
