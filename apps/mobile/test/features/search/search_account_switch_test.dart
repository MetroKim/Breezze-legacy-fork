import 'package:breezze/core/auth/auth_session.dart';
import 'package:breezze/features/search/search_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SwitchableAuthSession extends AuthSessionController {
  @override
  AuthState build() =>
      const AuthSignedIn(userId: 'alice', email: 'alice@example.test');

  void switchTo(String userId) {
    state = AuthSignedIn(userId: userId, email: '$userId@example.test');
  }
}

void main() {
  testWidgets('Search clears the prior listener query on account switch',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        authSessionProvider.overrideWith(_SwitchableAuthSession.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: bzLightTheme(),
          home: const Scaffold(body: SearchScreen()),
        ),
      ),
    );

    final inputFinder = find.byType(TextField).first;
    await tester.enterText(inputFinder, 'A');
    await tester.pump();
    expect(tester.widget<TextField>(inputFinder).controller!.text, 'A');

    (container.read(authSessionProvider.notifier) as _SwitchableAuthSession)
        .switchTo('bob');
    await tester.pump();

    expect(tester.widget<TextField>(inputFinder).controller!.text, isEmpty);
    expect(find.text('No results for "A"'), findsNothing);
  });
}
