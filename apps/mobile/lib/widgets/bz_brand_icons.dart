import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// Breezze icon primitive. Every interface glyph is rendered from SVG;
/// product marks are kept separate from the icon set.
class BzSvgIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const BzSvgIcon({
    super.key,
    required this.name,
    this.size = 22,
    this.color,
  });

  static const _paths = <String, String>{
    'info': '<circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/>',
    'help-circle': '<circle cx="12" cy="12" r="9"/><path d="M9.6 9a2.5 2.5 0 1 1 4.3 1.7c-1.1 1-1.9 1.4-1.9 3.1M12 17.5h.01"/>',
    'wifi-off': '<path d="M3 3 21 21M8.5 8.5A12 12 0 0 1 21 12M5 12a12 12 0 0 1 2.2-1.2M2 8a16 16 0 0 1 3.2-2M12 20h.01" />',
    'music-note': '<path d="M14.5 4.25v11.2a3.1 3.1 0 1 1-1.8-2.82V7.1l7-1.55v8.4a3.1 3.1 0 1 1-1.8-2.82V3.6l-3.4.65Z" />',
    'download': '<path d="M12 3.75v10.5m-4-4 4 4 4-4M4.5 16.5v2A1.75 1.75 0 0 0 6.25 20.25h11.5a1.75 1.75 0 0 0 1.75-1.75v-2" />',
    'chevron-left': '<path d="m15 18-6-6 6-6"/>',
    'chevron-right': '<path d="m9 18 6-6-6-6"/>',
    'plus': '<path d="M12 5v14M5 12h14"/>',
    'mic': '<rect x="9" y="2.5" width="6" height="12" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3.5M8.5 21.5h7"/>',
    'bell': '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/>',
    'disc-3': '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="1"/><path d="M12 3a9 9 0 0 1 9 9M3 12a9 9 0 0 0 9 9"/>',
    'smartphone': '<rect x="5.5" y="2.5" width="13" height="19" rx="2.2"/><path d="M10 18.5h4"/>',
    'user-round': '<circle cx="12" cy="8" r="3.5"/><path d="M4.5 21a7.5 7.5 0 0 1 15 0"/>',
    'search': '<circle cx="10.8" cy="10.8" r="6.8"/><path d="m16 16 4.25 4.25"/>',
    'close': '<path d="m6 6 12 12M18 6 6 18"/>',
    'history': '<path d="M3 12a9 9 0 1 0 2.6-6.3L3 8"/><path d="M3 3v5h5m4-1v5l3 2"/>',
    'chevron-down': '<path d="m6 9 6 6 6-6"/>',
    'more-vertical': '<circle cx="12" cy="5" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/><circle cx="12" cy="19" r="1" fill="currentColor"/>',
    'shuffle': '<path d="m16 3 5 5-5 5M3 7h2.5a5 5 0 0 1 4 2l5 6a5 5 0 0 0 4 2H21M16 21l5-5-5-5M3 17h2.5a5 5 0 0 0 3.3-1.25"/>',
    'skip-previous': '<path d="M5 5v14M19 5.5 8 12l11 6.5v-13Z"/>',
    'skip-next': '<path d="M19 5v14M5 5.5 16 12 5 18.5v-13Z"/>',
    'repeat': '<path d="m17 2 4 4-4 4M3 11V8a2 2 0 0 1 2-2h16M7 22l-4-4 4-4m14-1v3a2 2 0 0 1-2 2H3"/>',
    'pause': '<path d="M7 5.5A1.5 1.5 0 0 1 8.5 4h1A1.5 1.5 0 0 1 11 5.5v13a1.5 1.5 0 0 1-1.5 1.5h-1A1.5 1.5 0 0 1 7 18.5v-13Zm6 0A1.5 1.5 0 0 1 14.5 4h1A1.5 1.5 0 0 1 17 5.5v13a1.5 1.5 0 0 1-1.5 1.5h-1a1.5 1.5 0 0 1-1.5-1.5v-13Z"/>',
    'play': '<path d="M7.5 4.8a1 1 0 0 1 1.5-.86l10.1 7.06a1.2 1.2 0 0 1 0 2l-10.1 7.06a1 1 0 0 1-1.5-.86V4.8Z" fill="currentColor" stroke="none"/>',
    'favorite': '<path d="M20.5 8.8c0 4.5-8.5 10-8.5 10s-8.5-5.5-8.5-10A4.3 4.3 0 0 1 12 6.2a4.3 4.3 0 0 1 8.5 2.6Z"/>',
    'refresh': '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M5.5 9A7 7 0 0 1 18 6l2 1M4 17l2-1a7 7 0 0 0 12.5-3"/>',
    'trash': '<path d="M4 7h16M10 11v6m4-6v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    'download-done': '<path d="M12 3.5v10m-4-4 4 4 4-4M5 17v2.5h14V17M8.5 17l2 2 5-5"/>',
    'logout': '<path d="M10 4H5.5A1.5 1.5 0 0 0 4 5.5v13A1.5 1.5 0 0 0 5.5 20H10M15 16l4-4-4-4m4 4H9"/>',
    'lyrics': '<path d="M7 11h4v6H5v-6l3-5h3m6 5h4v6h-6v-6l3-5h3"/>',
    'share': '<path d="M12 15V3m-4 4 4-4 4 4M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/>',
    'queue': '<path d="M4 5h16M4 10h16M4 15h10M4 20h7m5-5 4 4 3-4"/>',
    'star-filled': '<path d="M12 3.25 14.7 8.73l6.05.88-4.38 4.27 1.03 6.03L12 17.06l-5.4 2.85 1.03-6.03-4.38-4.27 6.05-.88L12 3.25Z" fill="currentColor" stroke="none"/>',
    'star': '<path d="m12 3.25 2.7 5.48 6.05.88-4.38 4.27 1.03 6.03L12 17.06l-5.4 2.85 1.03-6.03L3.25 9.61l6.05-.88L12 3.25Z"/>',
    'drag-handle': '<path d="M8 5h8M8 12h8M8 19h8"/>',
    'volume-2': '<path d="M4 10v4h3l5 4V6l-5 4H4Z"/><path d="M16 9a5 5 0 0 1 0 6m2.5-9a9 9 0 0 1 0 12"/>',
    'infinity': '<path d="M8.2 8.2c-2.4-2.4-5.7-.8-5.7 3.8s3.3 6.2 5.7 3.8l7.6-7.6c2.4-2.4 5.7-.8 5.7 3.8s-3.3 6.2-5.7 3.8L8.2 8.2Z"/>',
    'clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
    'settings': '<circle cx="12" cy="12" r="3"/><path d="m19.4 15 .1.1 1.4 1.1-1.4 2.4-1.7-.7a8 8 0 0 1-1.6.9l-.3 1.8h-2.8l-.3-1.8a8 8 0 0 1-1.6-.9l-1.7.7-1.4-2.4 1.4-1.1a7 7 0 0 1 0-1.9L6.1 12l1.4-2.4 1.7.7a8 8 0 0 1 1.6-.9l.3-1.8h2.8l.3 1.8a8 8 0 0 1 1.6.9l1.7-.7 1.4 2.4-1.4 1.1a7 7 0 0 1-.1 1.9Z"/>',
    'moon': '<path d="M20.5 14.2A8.5 8.5 0 0 1 9.8 3.5 8.7 8.7 0 1 0 20.5 14.2Z"/>',
    'globe': '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',

    'airplay': '<path d="M5 4.5h14A2.5 2.5 0 0 1 21.5 7v9A2.5 2.5 0 0 1 19 18.5h-2.5M7.5 18.5H5A2.5 2.5 0 0 1 2.5 16V7A2.5 2.5 0 0 1 5 4.5Z"/><path d="m8 21 4-5 4 5"/>',
    'calendar': '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4m10-4v4M3 10h18"/>',
    'compass': '<circle cx="12" cy="12" r="9"/><path d="m15.8 8.2-2.4 5.2-5.2 2.4 2.4-5.2 5.2-2.4Z"/>',
    'grid': '<rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="3" width="8" height="8" rx="1.5"/><rect x="3" y="13" width="8" height="8" rx="1.5"/><rect x="13" y="13" width="8" height="8" rx="1.5"/>',
    'video': '<rect x="3" y="5" width="13" height="14" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
    'headphones': '<path d="M3 13v-1a9 9 0 0 1 18 0v1"/><rect x="3" y="12" width="4" height="8" rx="2"/><rect x="17" y="12" width="4" height="8" rx="2"/>',
    'filter': '<path d="M4 6h16M7 12h10m-7 6h4"/>',
    'list-music': '<path d="M4 6h10M4 11h10M4 16h6"/><path d="M18 4v12.5a2.5 2.5 0 1 1-2-2.45V7l6-1.5v8.5"/>',
    'album': '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2"/><path d="M12 3a9 9 0 0 1 9 9"/>',
    'sun': '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'arrow-up-right': '<path d="M7 17 17 7M8 7h9v9"/>',
    'check': '<path d="m5 12 4 4L19 6"/>',
    'google': '<path d="M21.35 11.1H12v3.08h5.35A4.8 4.8 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6a5.8 5.8 0 0 1 4.09 1.62l2.27-2.27A9.1 9.1 0 0 0 12 3a9 9 0 1 0 9 9c0-.3-.03-.6-.07-.9Z" fill="currentColor" stroke="none"/>',
    'apple': '<path d="M17.2 13.1c-.2-2 1.6-3 1.7-3.1-1-1.5-2.6-1.7-3.2-1.7-1.4-.2-2.8.8-3.5.8-.8 0-1.9-.8-3.1-.8-1.6 0-3.1.9-4 2.3-1.7 2.9-.5 7.2 1.2 9.4.8 1.1 1.8 2.3 3 2.2 1.1 0 1.5-.7 3.1-.7s2 .7 3.1.7c1.3 0 2.1-1.1 2.9-2.2.9-1.3 1.2-2.4 1.2-2.4-.1-.1-2.1-.9-2.2-3.3ZM14.9 6.7c.7-.9 1.2-2 1.1-3.2-1 .1-2.1.7-2.8 1.5-.7.8-1.3 1.9-1.2 3 1.1.1 2.1-.5 2.9-1.3Z" fill="currentColor" stroke="none"/>',
    'eye': '<path d="M2.5 12S6 5.5 12 5.5s9.5 6.5 9.5 6.5S18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="3"/>',
    'eye-off': '<path d="M3 3 21 21M10.5 5.6A10.5 10.5 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-3.8 4.5M6.3 6.6C3.8 8.3 2.5 12 2.5 12S6 18.5 12 18.5a9.7 9.7 0 0 0 3.1-.5M10 10a3 3 0 0 0 4 4"/>',
    'user-round-plus': '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 21a6.5 6.5 0 0 1 13 0m3-13v8m-4-4h8"/>',
    'wifi': '<path d="M2 8.5a15 15 0 0 1 20 0M5 12a10 10 0 0 1 14 0m-11 3.5a5 5 0 0 1 8 0M12 20h.01"/>',
  };

  @override
  Widget build(BuildContext context) {
    final stroke = color ?? Theme.of(context).colorScheme.onSurface;
    final path = _paths[name];
    if (path == null) {
      return SizedBox(
        width: size,
        height: size,
        child: const Center(child: SizedBox(width: 4, height: 4)),
      );
    }
    return SvgPicture.string(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">$path</svg>',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(stroke, BlendMode.srcIn),
    );
  }
}

/// Breezze app mark rendered from its SVG source.
class BzBnoteMark extends StatelessWidget {
  final double size;
  final Color? color;

  const BzBnoteMark({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      Theme.of(context).brightness == Brightness.dark
          ? 'assets/icons/breezze-symbol-white.svg'
          : 'assets/icons/breezze-symbol-black.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? Theme.of(context).colorScheme.onSurface,
        BlendMode.srcIn,
      ),
    );
  }
}

/// Ribbon wordmark. Kept as a brand illustration, not an interface icon.
class BzRibbonLogo extends StatelessWidget {
  final double width;
  final Color? color;

  const BzRibbonLogo({super.key, this.width = 120, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return Image.asset(
      Theme.of(context).brightness == Brightness.dark
          ? 'assets/icons/breezze-logo-white.png'
          : 'assets/icons/breezze-logo-black.png',
      width: width,
      height: width / 4,
      fit: BoxFit.contain,
      color: c,
      colorBlendMode: BlendMode.srcIn,
      semanticLabel: 'Breezze',
    );
  }
}
