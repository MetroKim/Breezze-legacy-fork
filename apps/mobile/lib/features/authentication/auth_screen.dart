import '../search/search_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/auth/auth_session.dart';
import '../../core/api/breezze_api.dart';
import '../../widgets/bz_brand_icons.dart';

/// Auth screen — login + register in one premium glass card, wired to
/// the real backend session controller.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.startInRegisterMode = false});

  final bool startInRegisterMode;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  final _mfaCode = TextEditingController();
  bool _registerMode = false;
  bool _revealPassword = false;
  late Future<Map<String, dynamic>> _socialProviders;
  bool _mfaBusy = false;
  String? _mfaError;

  @override
  void initState() {
    super.initState();
    _registerMode = widget.startInRegisterMode;
    _socialProviders = _prepareSocialFlows();
  }

  Future<Map<String, dynamic>> _prepareSocialFlows() async {
    try {
      final api = ref.read(authSessionProvider.notifier).api;
      final flags = await api.socialProviders()
          .timeout(const Duration(seconds: 10));
      final result = Map<String, dynamic>.from(flags);
      for (final provider in const ['apple', 'google']) {
        if (result[provider] == true) {
          try {
            result['${provider}Flow'] = await api.startSocialLogin(provider)
                .timeout(const Duration(seconds: 10));
          } catch (_) {
            // A failed preflight disables only that button; email and the
            // other provider remain available.
          }
        }
      }
      return result;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  bool _freshFlow(Object? raw) {
    if (raw is! Map || raw['expiresAt'] is! String) return false;
    final until = DateTime.tryParse(raw['expiresAt'] as String);
    return until != null &&
        until.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 15)));
  }

  Future<void> _signInWith(String provider, Map flow) async {
    if (_freshFlow(flow)) {
      await ref.read(authSessionProvider.notifier).socialLogin(
        provider,
        preparedFlow: Map<String, dynamic>.from(flow),
      );
    }
    // Refresh one-time flows after cancellation, expiry or a failed attempt.
    if (mounted && ref.read(authSessionProvider) is! AuthSignedIn) {
      setState(() => _socialProviders = _prepareSocialFlows());
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    _mfaCode.dispose();
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
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      if (next is AuthSignedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          // Auth can also be the root onboarding route, which is replaced by
          // the signed-in shell; only pop when it was opened as a subroute.
          if (navigator.canPop()) navigator.popUntil((route) => route.isFirst);
        });
      }
    });
    final theme = Theme.of(context);
    final auth = ref.watch(authSessionProvider);
    final busy = auth is AuthSigningIn;
    final socialBusy = auth is AuthSigningIn && auth.social;
    final error = auth is AuthError ? auth.code : null;

    if (auth is AuthMfaRequired) return _buildMfaRequired(context, auth);
    if (auth is AuthMfaRecoveryCodes) return _buildRecoveryCodes(context, auth);

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
                      child: _loginPanel(context, busy: busy, error: error,
                        socialBusy: socialBusy),
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
    required bool socialBusy,
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
              FutureBuilder<Map<String, dynamic>>(
                future: _socialProviders,
                builder: (context, snapshot) {
                  final providers = snapshot.data ?? const <String, dynamic>{};
                  final googleFlow = providers['googleFlow'];
                  final appleFlow = providers['appleFlow'];
                  final googleReady = _freshFlow(googleFlow);
                  final appleReady = _freshFlow(appleFlow);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _socialButton(
                        label: 'Continue with Apple',
                        isApple: true,
                        enabled: appleReady && !busy,
                        onPressed: () => _signInWith('apple', appleFlow as Map),
                      ),
                      const SizedBox(height: 12),
                      _socialButton(
                        label: 'Continue with Google',
                        isApple: false,
                        enabled: googleReady && !busy,
                        onPressed: () => _signInWith('google', googleFlow as Map),
                      ),
                      if (!googleReady || !appleReady) ...[
                        const SizedBox(height: 12),
                        Text(
                          snapshot.connectionState == ConnectionState.waiting
                              ? 'Preparing secure sign-in providers…'
                              : (providers['google'] == true ||
                                  providers['apple'] == true)
                                ? 'Provider sign-in is unavailable or expired. '
                                  'You can refresh it, or continue with email.'
                                : 'Continue with your email address.',
                          style: TextStyle(
                            color: theme.bzText2,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                        if (snapshot.connectionState != ConnectionState.waiting)
                          TextButton(
                            onPressed: busy ? null : () => setState(() {
                              _socialProviders = _prepareSocialFlows();
                            }),
                            child: const Text('Refresh social sign-in'),
                          ),
                      ],
                    ],
                  );
                },
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
              if (socialBusy) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => ref.read(authSessionProvider.notifier)
                      .cancelSocialLogin(),
                  child: const Text('Cancel sign-in'),
                ),
              ],
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


  Future<void> _runMfa(Future<void> Function() action) async {
    setState(() {
      _mfaBusy = true;
      _mfaError = null;
    });
    try {
      await action();
    } on BreezzeApiException catch (error) {
      if (mounted) setState(() => _mfaError = error.code);
    } catch (_) {
      if (mounted) setState(() => _mfaError = 'NETWORK_ERROR');
    } finally {
      if (mounted) setState(() => _mfaBusy = false);
    }
  }

  Widget _buildMfaRequired(BuildContext context, AuthMfaRequired auth) {
    final theme = Theme.of(context);
    final controller = ref.read(authSessionProvider.notifier);
    final setupStarted = auth.provisioningUri != null && auth.secret != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  BzRibbonLogo(width: 104, color: theme.bzText1),
                  const SizedBox(height: 20),
                  Text(
                    auth.setupRequired ? 'Secure your administrator account' : 'Two-factor verification',
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    auth.setupRequired
                        ? 'Set up an authenticator before accessing administrator tools.'
                        : 'Enter the current code from your authenticator app, or use a recovery code.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.bzText2),
                  ),
                  const SizedBox(height: 24),
                  BzGlassContainer(
                    radius: BzRadius.card,
                    blur: 24,
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (auth.setupRequired && !setupStarted) ...[
                            Text('Confirm your password to begin MFA enrollment.',
                                style: TextStyle(color: theme.bzText2)),
                            const SizedBox(height: 12),
                            _field(
                              controller: _password,
                              hint: 'Current password',
                              icon: Icons.lock_outline,
                              obscure: true,
                            ),
                            const SizedBox(height: 16),
                            _SubmitButton(
                              label: 'Set up authenticator',
                              busy: _mfaBusy,
                              onPressed: () => _runMfa(
                                () => controller.beginMfaSetup(_password.text),
                              ),
                            ),
                          ] else ...[
                            if (setupStarted) ...[
                              Text('Add this account to your authenticator app.',
                                  style: TextStyle(color: theme.bzText2)),
                              const SizedBox(height: 10),
                              SelectableText(auth.secret!,
                                  style: TextStyle(
                                    color: theme.bzText1,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  )),
                              const SizedBox(height: 8),
                              SelectableText(auth.provisioningUri!,
                                  style: TextStyle(fontSize: 11, color: theme.bzText2)),
                              const SizedBox(height: 16),
                            ],
                            _field(
                              controller: _mfaCode,
                              hint: '6-digit code or recovery code',
                              icon: Icons.verified_user_outlined,
                              keyboard: TextInputType.text,
                            ),
                            const SizedBox(height: 16),
                            _SubmitButton(
                              label: auth.setupRequired ? 'Verify and enable MFA' : 'Verify and continue',
                              busy: _mfaBusy,
                              onPressed: () => _runMfa(
                                () => auth.setupRequired
                                    ? controller.verifyMfaSetup(_mfaCode.text.trim())
                                    : controller.verifyMfa(_mfaCode.text.trim()),
                              ),
                            ),
                          ],
                          if (_mfaError != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _mfaError == 'MFA_CODE_REPLAYED'
                                  ? 'That code has already been used. Wait for the next code.'
                                  : _mfaError == 'INVALID_CREDENTIALS'
                                      ? 'Password confirmation failed.'
                                      : 'Verification failed. Check the code and try again.',
                              style: TextStyle(color: theme.bzError),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _mfaBusy
                        ? null
                        : () => controller.signOut(),
                    child: Text('Sign out', style: TextStyle(color: theme.bzText2)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecoveryCodes(BuildContext context, AuthMfaRecoveryCodes auth) {
    final theme = Theme.of(context);
    final controller = ref.read(authSessionProvider.notifier);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  BzRibbonLogo(width: 104, color: theme.bzText1),
                  const SizedBox(height: 20),
                  Text('Save your recovery codes',
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    'Each code works once if you lose access to your authenticator. They will not be shown again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.bzText2),
                  ),
                  const SizedBox(height: 20),
                  BzGlassContainer(
                    radius: BzRadius.card,
                    blur: 24,
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: SelectableText(
                        auth.codes.join('\n'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: theme.bzText1,
                          fontWeight: FontWeight.w700,
                          height: 1.8,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SubmitButton(
                    label: 'I have saved my codes',
                    busy: false,
                    onPressed: controller.completeMfaEnrollment,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _errorText(String code) {
    switch (code) {
      case 'EMAIL_TAKEN':
        return 'That email is already registered.';
      case 'INVALID_CREDENTIALS':
        return 'Wrong email or password.';
      case 'NETWORK_ERROR':
        return 'Cannot reach Breezze. Check your connection.';
      case 'SOCIAL_ACCOUNT_LINK_REQUIRED':
        return 'An account already uses this email. Sign in with email first.';
      case 'SOCIAL_AUTH_EXPIRED':
        return 'The browser sign-in expired. Try again.';
      case 'SOCIAL_PROVIDER_NOT_CONFIGURED':
        return 'This sign-in provider is not configured yet.';
      case 'SOCIAL_AUTH_FAILED':
        return 'Secure sign-in did not finish. Please retry or use email.';
      default:
        return 'Something went wrong. Try again.';
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: theme.bzSurface1,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BzRadius.input),
          borderSide: BorderSide(color: theme.bzSeparator),
        ),
      ),
    );
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
