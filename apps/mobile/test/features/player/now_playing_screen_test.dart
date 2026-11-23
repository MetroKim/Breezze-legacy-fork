import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:breezze/features/player/now_playing_screen.dart';

class _PlayerLauncher extends StatelessWidget {
  const _PlayerLauncher();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const NowPlayingScreen(),
              ),
            ),
            child: const Text('Open player'),
          ),
        ),
      );
}

void main() {
  testWidgets('empty Now Playing offers an accessible way back', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: bzLightTheme(),
          home: const _PlayerLauncher(),
        ),
      ),
    );

    await tester.tap(find.text('Open player'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.text('Back to music'), findsOneWidget);

    await tester.tap(find.text('Back to music'));
    await tester.pumpAndSettle();

    expect(find.text('Open player'), findsOneWidget);
    expect(find.text('Nothing playing'), findsNothing);
  });
}
