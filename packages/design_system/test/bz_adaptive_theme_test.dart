import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('black and white icon colors preserve Breezze monochrome', () {
    final dark = bzColorsFromBrandSeed(
      brightness: Brightness.dark,
      seedColor: const Color(0xFF000000),
    );
    final light = bzColorsFromBrandSeed(
      brightness: Brightness.light,
      seedColor: const Color(0xFFFFFFFF),
    );
    expect(dark.accent, BzThemeColors.dark.accent);
    expect(light.accent, BzThemeColors.light.accent);
  });

  test('saturated brand seeds can adapt light and dark themes', () {
    const seed = Color(0xFF2469E8);
    final light = bzColorsFromBrandSeed(
      brightness: Brightness.light, seedColor: seed,
    );
    final dark = bzColorsFromBrandSeed(
      brightness: Brightness.dark, seedColor: seed,
    );
    expect(light.background, BzThemeColors.light.background);
    expect(dark.background, BzThemeColors.dark.background);
    expect(light.accent, isNot(BzThemeColors.light.accent));
    expect(dark.accent, isNot(BzThemeColors.dark.accent));
    expect(bzLightTheme(brandSeed: seed).bz.accent, light.accent);
    expect(bzDarkTheme(brandSeed: seed).bz.accent, dark.accent);
  });

  test('contrast of adapted accents meets 4.5:1 on the main surface', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final c = bzColorsFromBrandSeed(
        brightness: brightness, seedColor: const Color(0xFF2469E8),
      );
      final accent = c.accent.computeLuminance();
      final background = c.background.computeLuminance();
      final ratio = (accent > background
          ? (accent + 0.05) / (background + 0.05)
          : (background + 0.05) / (accent + 0.05));
      expect(ratio, greaterThanOrEqualTo(4.5));
    }
  });

  test('a missing or invalid seed retains the safe baseline', () {
    expect(
      bzColorsFromBrandSeed(brightness: Brightness.light).accent,
      BzThemeColors.light.accent,
    );
    expect(
      bzColorsFromBrandSeed(
        brightness: Brightness.dark,
        seedColor: const Color(0xFF111111),
      ).accent,
      BzThemeColors.dark.accent,
    );
  });
}
