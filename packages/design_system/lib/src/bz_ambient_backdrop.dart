import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'bz_theme.dart';

/// BzAmbientBackdrop — content is the colour (Liner principle, Breezze
/// execution). Artwork blooms softly behind the screen chrome.
///
/// Artwork stays visible above the contrast gradient behind the controls.
class BzAmbientBackdrop extends StatelessWidget {
  final Widget child;
  final String? artworkUrl;
  final Color? artworkAccent;

  const BzAmbientBackdrop({
    super.key,
    required this.child,
    this.artworkUrl,
    this.artworkAccent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.bz;
    final seeded = bzColorsFromBrandSeed(
      brightness: theme.brightness, seedColor: artworkAccent,
    );
    final tint = artworkAccent != null && seeded.accent != colors.accent
        ? seeded.accent : null;

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: colors.background),
        if (artworkUrl != null)
          Image.network(
            artworkUrl!,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        if (tint != null)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: 0.16),
                    tint.withValues(alpha: 0.02),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  colors.background.withValues(alpha: 0.72),
                  colors.background.withValues(alpha: 0.83),
                  colors.background,
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
