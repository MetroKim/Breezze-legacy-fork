import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('track skeleton renders with reduced motion enabled',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: bzLightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: BzSkeletonTrackRow(),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BzSkeleton), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('responsive bottom clearance adapts to desktop width',
      (tester) async {
    double? compactInset;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Builder(
            builder: (context) {
              compactInset = BzBreakpoints.bottomClearance(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(compactInset, 218);

    double? desktopInset;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 800)),
          child: Builder(
            builder: (context) {
              desktopInset = BzBreakpoints.bottomClearance(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(desktopInset, 24);
  });

  // --- Liquid Glass material contract (PRT-09) ---
  // Glass is never mandatory: under high contrast the container must
  // render its solid-surface branch with no BackdropFilter in the tree.
  testWidgets('glass container falls back to solid surface on high contrast',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: bzLightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            highContrast: true,
          ),
          child: const Scaffold(
            body: Center(
              child: BzGlassContainer(
                radius: 999,
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass container renders backdrop filter in normal mode',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: bzDarkTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: const Scaffold(
            body: Center(
              child: BzGlassContainer(
                radius: 999,
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
