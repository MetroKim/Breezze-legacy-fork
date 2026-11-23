import '../search/search_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/auth/auth_session.dart';
import '../../widgets/bz_brand_icons.dart';

/// Auth screen — login + register in one premium glass card, wired to
/// the real backend session controller.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  bool _registerMode = false;
  bool _revealPassword = false;
  Future<void> _signInWith(String provider) async {
    await ref.read(authSessionProvider.notifier).socialLogin(provider);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = ref.read(authSessionProvider.notifier);
    if (_registerMode) {
      await controller.register(
        _email.text.trim(),
        _password.text,
        displayName: _displayName.text.trim().isEmpty
            ? null
            : _displayName.text.trim(),
      );
    } else {
      await controller.login(_email.text.trim(), _password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = ref.watch(authSessionProvider);
    final busy = auth is AuthSigningIn;
    final error = auth is AuthError ? auth.code : null;

    if (auth is AuthEmailConfirmationRequired) {
      return Scaffold(
        backgroundColor: theme.bzBackground,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                BzRibbonLogo(width: 160, color: theme.bzText1),
                const SizedBox(height: 24),
                Text('Check your email', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 12),
                Text('We sent a confirmation link to ${auth.email}. '
                    'Confirm your address, then sign in to Breezze.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => ref.read(authSessionProvider.notifier)
                      .resetToSignedOut(),
                  child: const Text('Back to sign in'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final desktop = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      backgroundColor: theme.bzBackground,
      body: LayoutBuilder(
        builder: (context, bounds) => Row(
          children: [
            if (desktop)
              Expanded(
                child: _editorialPanel(theme),
              ),
            Expanded(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: bounds.maxWidth < 440 ? 16 : 32,
                      vertical: 28,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _loginPanel(context, busy: busy, error: error),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorialPanel(ThemeData theme) {
    return ColoredBox(
      color: theme.bzSurface1,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: BzRibbonLogo(width: 340, color: theme.bzText1),
        ),
      ),
    );
  }

  Widget _loginPanel(BuildContext context, {
    required bool busy,
    required String? error,
  }) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (MediaQuery.sizeOf(context).width < 980) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: BzRibbonLogo(width: 168, color: theme.bzText1),
          ),
          const SizedBox(height: 28),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 34),
          decoration: BoxDecoration(
            color: theme.bzSurface1,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: theme.bzSeparator),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _registerMode ? 'Create your account' : 'Welcome to Breezze',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _registerMode ? 'Save music and build your first playlist.'
                    : 'Sign in to open your library and playlists.',
                style: TextStyle(
                  fontSize: BzType.body,
                  color: theme.bzText2,
                ),
              ),
              const SizedBox(height: 28),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Scaffold(appBar: AppBar(), body: const SearchScreen()))),
                child: const Text('Browse music'),
              ),
              const SizedBox(height: 12),
              _socialButton(
                label: 'Continue with Apple',
                isApple: true,
                enabled: !busy,
                onPressed: () => _signInWith('apple'),
              ),
              const SizedBox(height: 12),
              _socialButton(
                label: 'Continue with Google',
                isApple: false,
                enabled: !busy,
                onPressed: () => _signInWith('google'),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: Divider(color: theme.bzSeparator)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text('or use email',
                        style: TextStyle(color: theme.bzText2, fontSize: 12)),
                  ),
                  Expanded(child: Divider(color: theme.bzSeparator)),
                ],
              ),
              const SizedBox(height: 24),
              AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_registerMode) ...[
                      _premiumField(
                        controller: _displayName,
                        label: 'Display name',
                        hint: 'Your name',
                        hints: const [AutofillHints.name],
                      ),
                      const SizedBox(height: 18),
                    ],
                    _premiumField(
                      controller: _email,
                      label: 'Email address',
                      hint: 'you@example.com',
                      hints: const [AutofillHints.email],
                      keyboard: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 18),
                    _premiumField(
                      controller: _password,
                      label: 'Password',
                      hint: 'Enter your password',
                      hints: [_registerMode
                          ? AutofillHints.newPassword
                          : AutofillHints.password],
                      obscure: !_revealPassword,
                      suffix: IconButton(
                        tooltip: _revealPassword ? 'Hide password' : 'Show password',
                        onPressed: () => setState(
                          () => _revealPassword = !_revealPassword,
                        ),
                        icon: Icon(_revealPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                      ),
                      onSubmitted: (_) => !busy ? _submit() : null,
                    ),
                  ],
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(_errorText(error), style: TextStyle(
                    color: theme.bzError, fontSize: 13,
                  )),
                ),
              ],
              const SizedBox(height: 24),
              _SubmitButton(
                label: _registerMode ? 'Create account' : 'Continue with email',
                busy: busy,
                onPressed: _submit,
              ),
              const SizedBox(height: 22),
              Center(
                child: TextButton(
                  onPressed: busy ? null : () => setState(
                    () => _registerMode = !_registerMode,
                  ),
                  child: Text(
                    _registerMode
                        ? 'Already have an account? Sign in'
                        : 'New to Breezze? Create an account',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.bzText1),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'By continuing, you agree to our Terms and Privacy Policy.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: theme.bzText2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'FREE LISTENING · SECURE ACCOUNT · DEVICE SYNC',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.1,
            color: theme.bzText2,
          ),
        ),
      ],
    );
  }

  Widget _premiumField({
    required TextEditingController controller,
    required String label,
    required String hint,
    List<String>? hints,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
    ValueChanged<String>? onSubmitted,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(
          color: theme.bzText1, fontWeight: FontWeight.w600, fontSize: 13,
        )),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          autofillHints: hints,
          keyboardType: keyboard,
          textInputAction: label == 'Password'
              ? TextInputAction.done : TextInputAction.next,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffix,
            filled: true,
            fillColor: theme.bzSurface2,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18, vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: theme.bzSeparator),
            ),
          ),
        ),
      ],
    );
  }

  Widget _socialButton({
    required String label,
    required bool isApple,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    const googleMark = '<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 24 24"><path fill="#4285F4" d="M22.5 12.25c0-.75-.08-1.5-.2-2.2H12v4.15h5.9a5.06 5.06 0 01-2.2 3.3v2.7h3.55c2.06-1.9 3.25-4.7 3.25-7.95z"/>'
        '<path fill="#34A853" d="M12 23c2.93 0 5.4-.97 7.2-2.8l-3.55-2.7c-.98.67-2.22 1.05-3.65 1.05-2.8 0-5.18-1.9-6.03-4.45H2.3v2.8A11 11 0 0012 23z"/>'
        '<path fill="#FBBC05" d="M5.97 14.1A6.64 6.64 0 015.62 12c0-.73.13-1.44.35-2.1V7.1H2.3A11 11 0 001 12c0 1.77.42 3.45 1.3 4.9l3.67-2.8z"/>'
        '<path fill="#EA4335" d="M12 5.45c1.6 0 3.05.55 4.18 1.65L19.3 4A10.4 10.4 0 0012 1C7.7 1 3.98 3.45 2.3 7.1l3.67 2.8C6.82 7.35 9.2 5.45 12 5.45z"/></svg>';
    const appleMark = '<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 24 28"><path fill="currentColor" d="M18.7 14.9c0-2.4 1.9-3.6 2-3.7-1.1-1.7-2.9-2-3.5-2.1-1.5-.2-3 .9-3.7.9-.8 0-1.9-.9-3.2-.9-1.7 0-3.2 1-4 2.5-1.7 3-1.2 7.3 1.2 9.9.8 1.3 1.7 2.7 3 2.7 1.2-.1 1.7-.8 3.2-.8s1.9.8 3.3.8c1.4 0 2.2-1.2 3-2.5.9-1.4 1.3-2.7 1.3-2.8-.1 0-2.6-1-2.6-3.9zM16.3 6.8c.7-.9 1.2-2 1.1-3.1-1 .1-2.2.7-2.9 1.6-.7.8-1.3 2-1.2 3 .1 0 1.9.1 3-1.5z"/></svg>';
    return SizedBox(
      height: 54,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: SvgPicture.string(isApple ? appleMark : googleMark,
          width: 21, height: 22,
          colorFilter: isApple
              ? ColorFilter.mode(theme.bzText1, BlendMode.srcIn) : null,
        ),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.bzText1,
          backgroundColor: theme.bzSurface2,
          disabledForegroundColor: theme.bzText2,
          side: BorderSide(color: theme.bzSeparator),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }


  String _errorText(String code) {
    switch (code) {
      case 'INVALID_CREDENTIALS':
        return 'Wrong email or password.';
      case 'PASSWORD_TOO_SHORT':
        return 'Choose a longer password.';
      case 'GOOGLE_SETUP_REQUIRED':
        return 'Google Sign-In needs its Google Cloud client IDs configured.';
      case 'APPLE_UNAVAILABLE':
        return 'Apple Sign-In is not supported on this device.';
      case 'RATE_LIMITED':
        return 'Too many attempts. Try again later.';
      case 'NETWORK_ERROR':
        return 'Cannot reach Supabase Auth. Check your connection.';
      case 'AUTH_FAILED':
        return 'Sign-in failed. Check your details or try another method.';
      case 'SOCIAL_AUTH_FAILED':
        return 'Secure sign-in did not finish. Please retry.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }


}

class _SubmitButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  const _SubmitButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: busy ? null : onPressed,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: theme.bzText1,
          borderRadius: BorderRadius.circular(BzRadius.button),
        ),
        child: Center(
          child: busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.bzBackground,
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontSize: BzType.subheadline,
                    fontWeight: FontWeight.w600,
                    color: theme.bzBackground,
                  ),
                ),
        ),
      ),
    );
  }
}
