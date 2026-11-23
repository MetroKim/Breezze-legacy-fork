import 'package:breezze/core/auth/auth_session.dart';
import 'package:breezze/features/settings/account_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _GuestAuthSession extends AuthSessionController {
  @override
  AuthState build() => const AuthSignedOut();
}

void main() {
  testWidgets('signed-out account shows a real gateway instead of fetching sessions',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionProvider.overrideWith(_GuestAuthSession.new),
        ],
        child: MaterialApp(
          theme: bzLightTheme(),
          home: const AccountScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Your music, your account'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Continue without an account'), findsOneWidget);
    expect(find.text('No active sessions found'), findsNothing);
  });
}
