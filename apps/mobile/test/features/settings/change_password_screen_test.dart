import 'package:breezze/core/auth/auth_session.dart';
import 'package:breezze/features/settings/change_password_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SignedInAuthSession extends AuthSessionController {
  @override
  AuthState build() => const AuthSignedIn(
    userId: 'test-user', email: 'listener@example.test',
  );
}

void main() {
  testWidgets('password change rejects weak passwords without contacting the API',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authSessionProvider.overrideWith(_SignedInAuthSession.new)],
        child: MaterialApp(
          theme: bzLightTheme(),
          home: const ChangePasswordScreen(),
        ),
      ),
    );
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'old-password-strong');
    await tester.enterText(fields.at(1), 'short');
    await tester.enterText(fields.at(2), 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
    await tester.pump();
    expect(find.text('Use at least 12 characters'), findsOneWidget);
  });
}
