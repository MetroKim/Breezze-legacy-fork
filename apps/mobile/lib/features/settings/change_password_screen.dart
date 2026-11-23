import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_session.dart';

/// Password changes revoke every device session; no password is persisted
/// locally and the user must sign in again after the server acknowledges.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitting = false;
  String? _failure;

  @override
  void dispose() {
    _current.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    if (_submitting || _formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      await ref.read(authSessionProvider.notifier).api.changePassword(
        currentPassword: _current.text,
        newPassword: _newPassword.text,
      );
      // The backend revoked all refresh token families in the same
      // transaction as the password change. Erase this device's token too.
      await ref.read(authSessionProvider.notifier).signOut();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (mounted) {
        setState(() => _failure =
            'Could not change your password. Check the current password '
            'and your connection, then try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
            children: [
              Text('Secure your account', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Choose a password of at least 12 characters. '
                'For security, this will sign you out of all devices.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 26),
              TextFormField(
                controller: _current,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Current password'),
                validator: (value) => value == null || value.isEmpty
                    ? 'Enter your current password' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newPassword,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'New password'),
                validator: (value) {
                  if (value == null || value.length < 12) {
                    return 'Use at least 12 characters';
                  }
                  if (value.length > 128) return 'Maximum 128 characters';
                  if (value == _current.text) return 'Choose a new password';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _changePassword(),
                decoration: const InputDecoration(labelText: 'Confirm new password'),
                validator: (value) => value != _newPassword.text
                    ? 'Passwords do not match' : null,
              ),
              if (_failure != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(_failure!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _changePassword,
                child: Text(_submitting ? 'Updating…' : 'Change password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
