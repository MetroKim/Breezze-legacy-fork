import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_session.dart';

enum _SignOutScope { thisDevice, allDevices }

/// Shared sign-out confirmation for Settings and the account page.
/// The all-devices action requires a server acknowledgement before local
/// credentials are erased; an offline client cannot revoke remote devices.
Future<void> confirmBreezzeSignOut(BuildContext context, WidgetRef ref) async {
  final scope = await showDialog<_SignOutScope>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sign out of Breezze?'),
      content: const Text(
        'Your saved account data will stay private. Sign out of all devices '
        'requires an internet connection and will end every active session.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(_SignOutScope.thisDevice),
          child: const Text('This device'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(_SignOutScope.allDevices),
          child: const Text('All devices'),
        ),
      ],
    ),
  );
  if (!context.mounted || scope == null) return;
  try {
    await ref.read(authSessionProvider.notifier).signOut(
      allDevices: scope == _SignOutScope.allDevices,
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(
        'Could not revoke all sessions. Check your connection and retry.',
      )),
    );
  }
}
