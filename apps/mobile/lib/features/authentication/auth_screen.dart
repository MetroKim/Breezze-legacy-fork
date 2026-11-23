import '../search/search_screen.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_session.dart';
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
  final _oldPassword = TextEditingController();
  bool _registerMode = false;
  bool _revealPassword = false;
  bool _mfaBusy = false;
  bool _revealOldPassword = false;
  bool _resetBusy = false;
  String? _mfaError;

  @override
  void initState() {
    super.initState();
    _registerMode = widget.startInRegisterMode;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    _mfaCode.dispose();
    _oldPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = ref.read(authSessionProvider.notifier);
    if (_registerMode) {
      await controller.register(
        _email.text.trim(), _password.text,
        displayName: _displayName.text.trim().isEmpty
            ? null : _displayName.text.trim(),
      );
      if (mounted && ref.read(authSessionProvider) is AuthError &&
          (ref.read(authSessionProvider) as AuthError).code ==
              'EMAIL_VERIFICATION_REQUIRED') {
        _password.clear();
        setState(() => _registerMode = false);
      }
    } else {
      await controller.login(_email.text.trim(), _password.text);
    }
  }

  Future<void> _resetPassword() async {
    if (_resetBusy || _email.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address first.')),
      );
      return;
    }
    setState(() => _resetBusy = true);
    try {
      await ref.read(authSessionProvider.notifier)
          .requestPasswordReset(_email.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('If your account exists, check your email for a reset link.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password recovery is unavailable right now.')),
      );
    } finally {
      if (mounted) setState(() => _resetBusy = false);
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
    final needsClaim = error == 'SUPABASE_ACCOUNT_LINK_REQUIRED' ||
        error == 'SUPABASE_LEGACY_PASSWORD_INVALID';
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
                needsClaim
                    ? 'Restore your library'
                    : _registerMode ? 'Create your account' : 'Welcome to Breezze',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800, letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                needsClaim
                    ? 'Confirm your previous Breezze password to keep your playlists and favorites.'
                    : _registerMode
                        ? 'Save music and build your first playlist.'
                        : 'Sign in to open your library and playlists.',
                style: TextStyle(fontSize: BzType.body, color: theme.bzText2),
              ),
              const SizedBox(height: 28),
              if (!needsClaim) ...[
                OutlinedButton(
                  onPressed: busy ? null : () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(), body: const SearchScreen(),
                    ),
                  )),
                  child: const Text('Browse music'),
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
                          tooltip: _revealPassword
                              ? 'Hide password' : 'Show password',
                          onPressed: () => setState(
                            () => _revealPassword = !_revealPassword,
                          ),
                          icon: BzSvgIcon(
                            name: _revealPassword ? 'eye-off' : 'eye',
                            size: 20, color: theme.bzText2,
                          ),
                        ),
                        onSubmitted: (_) { if (!busy) _submit(); },
                      ),
                    ],
                  ),
                ),
              ] else ...[
                _premiumField(
                  controller: _oldPassword,
                  label: 'Previous Breezze password',
                  hint: 'Your previous account password',
                  hints: const [AutofillHints.password],
                  obscure: !_revealOldPassword,
                  suffix: IconButton(
                    tooltip: _revealOldPassword
                        ? 'Hide password' : 'Show password',
                    onPressed: () => setState(() =>
                        _revealOldPassword = !_revealOldPassword),
                    icon: BzSvgIcon(
                      name: _revealOldPassword ? 'eye-off' : 'eye',
                      size: 20, color: theme.bzText2,
                    ),
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _errorText(error),
                    style: TextStyle(
                      color: error == 'EMAIL_VERIFICATION_REQUIRED' ||
                              error == 'SUPABASE_ACCOUNT_LINK_REQUIRED'
                          ? theme.bzText1 : theme.bzError,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              _SubmitButton(
                label: needsClaim
                    ? 'Restore my Breezze library'
                    : _registerMode ? 'Create account' : 'Sign in',
                busy: busy,
                onPressed: needsClaim
                    ? () => ref.read(authSessionProvider.notifier)
                        .claimExistingLibrary(_email.text.trim(), _oldPassword.text)
                    : _submit,
              ),
              if (!needsClaim) ...[
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: busy ? null : () => setState(
                      () => _registerMode = !_registerMode,
                    ),
                    child: Text(
                      _registerMode
                          ? 'Already have an account? Sign in'
                          : 'New to Breezze? Create an account',
                      style: TextStyle(color: theme.bzText1),
                    ),
                  ),
                ),
                if (!_registerMode)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: busy || _resetBusy ? null : _resetPassword,
                      child: const Text('Forgot password?'),
                    ),
                  ),
              ] else ...[
                TextButton(
                  onPressed: busy ? null : () => ref
                      .read(authSessionProvider.notifier)
                      .login(_email.text.trim(), _password.text),
                  child: const Text('Sign in with another account'),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'By continuing, you agree to our Terms and Privacy Policy.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, height: 1.4,
                    color: theme.bzText2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'FREE LISTENING · SECURE ACCOUNT · DEVICE SYNC',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, letterSpacing: 1.1,
              color: theme.bzText2),
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
      case 'INVALID_CREDENTIALS':
        return 'Wrong email or password.';
      case 'EMAIL_VERIFICATION_REQUIRED':
        return 'Check your inbox and verify your email before signing in.';
      case 'SUPABASE_ACCOUNT_LINK_REQUIRED':
        return 'This Supabase account matches an existing Breezze library. Enter your previous Breezze password to link it securely.';
      case 'SUPABASE_LEGACY_PASSWORD_INVALID':
        return 'The previous Breezze password was incorrect.';
      case 'SUPABASE_ACCOUNT_MIGRATION_DISABLED':
        return 'Existing-account migration is not enabled yet.';
      case 'SUPABASE_CLAIM_NOT_READY':
        return 'Sign in with Supabase first, then restore your library.';
      case 'SUPABASE_AUTH_NOT_CONFIGURED':
        return 'Breezze sign-in is not configured yet.';
      case 'SUPABASE_AUTH_UNAVAILABLE':
        return 'Breezze sign-in is temporarily unavailable.';
      case 'RATE_LIMITED':
        return 'Too many attempts. Please try again later.';
      case 'NETWORK_ERROR':
        return 'Cannot reach Breezze. Check your connection.';
      default:
        return 'Sign-in could not finish. Please retry.';
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
