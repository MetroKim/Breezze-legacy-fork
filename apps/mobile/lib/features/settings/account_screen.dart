import 'package:material_ui/material_ui.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_session.dart';
import '../authentication/auth_screen.dart';
import 'account_sign_out.dart';
import 'change_password_screen.dart';
import '../../widgets/bz_brand_icons.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _name = TextEditingController();
  final _country = TextEditingController();
  final _language = TextEditingController();
  final _genres = TextEditingController();
  final _favoriteArtists = TextEditingController();
  List<Map<String, dynamic>> _sessions = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _email;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _country.dispose();
    _language.dispose();
    _genres.dispose();
    _favoriteArtists.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final initialAuth = ref.read(authSessionProvider);
    if (initialAuth is! AuthSignedIn) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final ownerId = initialAuth.userId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authSessionProvider.notifier).api;
      final results = await Future.wait([api.profile(), api.sessions()]);
      final latestAuth = ref.read(authSessionProvider);
      if (!mounted || latestAuth is! AuthSignedIn ||
          latestAuth.userId != ownerId) return;
      final profile = results[0] as Map<String, dynamic>;
      final preference = profile['preference'] is Map
          ? Map<String, dynamic>.from(profile['preference'] as Map)
          : <String, dynamic>{};
      setState(() {
        _name.text = profile['displayName'] as String? ?? '';
        _country.text = preference['country'] as String? ?? '';
        _language.text = preference['language'] as String? ?? '';
        _genres.text = (preference['genres'] as List<dynamic>? ?? const [])
            .whereType<String>().join(', ');
        _favoriteArtists.text =
            (preference['favoriteArtists'] as List<dynamic>? ?? const [])
                .whereType<String>().join(', ');
        _email = profile['email'] as String?;
        _sessions = results[1] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (_) {
      final latestAuth = ref.read(authSessionProvider);
      if (!mounted || latestAuth is! AuthSignedIn ||
          latestAuth.userId != ownerId) return;
      setState(() {
        _loading = false;
        _error = 'Account details could not be loaded. Check your connection and retry.';
      });
    }
  }

  Future<void> _saveProfile() async {
    final name = _name.text.trim();
    final country = _country.text.trim().toUpperCase();
    final language = _language.text.trim();
    if (name.isEmpty || name.length > 80) {
      setState(() => _error = 'Display name must be between 1 and 80 characters.');
      return;
    }
    if (country.isNotEmpty &&
        (country.length != 2 ||
            !country.codeUnits.every((unit) => unit >= 65 && unit <= 90))) {
      setState(() => _error = 'Country must be a two-letter ISO code, such as TZ.');
      return;
    }
    List<String> genres;
    List<String> artists;
    try {
      genres = _splitPreferenceList(_genres.text, maxItems: 20);
      artists = _splitPreferenceList(_favoriteArtists.text, maxItems: 50);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await ref.read(authSessionProvider.notifier).api.updateProfile(
            displayName: name,
            includePreferences: true,
            country: country.isEmpty ? null : country,
            language: language.isEmpty ? null : language,
            genres: genres,
            favoriteArtists: artists,
          );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile and listening preferences updated')),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Profile could not be saved. Please retry.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<String> _splitPreferenceList(String value, {required int maxItems}) {
    final values = value.split(',').map((item) => item.trim())
        .where((item) => item.isNotEmpty).toSet().toList(growable: false);
    if (values.length > maxItems) {
      throw FormatException('Maximum $maxItems values allowed.');
    }
    return values;
  }

  Future<void> _revoke(String id) async {
    try {
      await ref.read(authSessionProvider.notifier).api.revokeSession(id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session revoked')),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'That session could not be revoked.');
    }
  }

  Future<void> _deleteAccount() async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This permanently deletes your Breezze account and associated server data. This action cannot be undone.'),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm with your password'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete account')),
        ],
      ),
    );
    final value = password.text;
    password.dispose();
    if (confirmed != true || value.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(authSessionProvider.notifier).api.deleteAccount(password: value);
      await ref.read(authSessionProvider.notifier).signOut();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (mounted) setState(() => _error = 'Account deletion failed. Check your password and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _signedOutGateway(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
          children: [
            Center(child: BzBnoteMark(size: 72, color: theme.bzText1)),
            const SizedBox(height: 24),
            Text('Your music, your account',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text('Sign in to sync your library and playlists across devices. '
                'Breezze also lets you explore the public catalogue without an account.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.bzText2)),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuthScreen())),
              child: const Text('Sign in'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuthScreen(startInRegisterMode: true))),
              child: const Text('Create account'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Continue without an account'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      final before = previous is AuthSignedIn ? previous.userId : null;
      final after = next is AuthSignedIn ? next.userId : null;
      if (before == after) return;
      if (next is AuthSignedIn) {
        _load();
      } else {
        setState(() {
          _email = null;
          _sessions = const [];
          _error = null;
          _loading = false;
        });
      }
    });
    final theme = Theme.of(context);
    if (ref.watch(authSessionProvider) is! AuthSignedIn) {
      return _signedOutGateway(theme);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
        leading: IconButton(
          icon: BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: const [
                Center(child: BzSkeleton(width: 96, height: 96, radius: 48, circle: true)),
                SizedBox(height: 24),
                BzSkeleton(width: 180, height: 14, radius: 5),
                SizedBox(height: 14),
                BzSkeleton(width: double.infinity, height: 52, radius: 10),
                SizedBox(height: 28),
                BzSkeletonTrackRow(),
                SizedBox(height: 14),
                BzSkeletonTrackRow(),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: theme.bzSurface1,
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.bzSeparator),
                        ),
                        alignment: Alignment.center,
                        child: BzBnoteMark(size: 42, color: theme.bzText2),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Profile photo',
                        style: theme.textTheme.labelLarge,
                      ),
                      Text(
                        'Photo editing will be available when profile media support is connected.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Text(_email ?? '', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 12),
                Text('LISTENING PREFERENCES', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                TextField(controller: _country, maxLength: 2,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Country code', hintText: 'TZ', helperText: 'Two-letter country code used for availability.')),
                TextField(controller: _language, maxLength: 16,
                  decoration: const InputDecoration(labelText: 'Preferred language', hintText: 'en')),
                TextField(controller: _genres, maxLength: 800,
                  decoration: const InputDecoration(labelText: 'Favorite genres', hintText: 'Afrobeats, R&B, Hip-hop', helperText: 'Separate values with commas.')),
                TextField(controller: _favoriteArtists, maxLength: 4000, maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Favorite artists', hintText: 'Artist One, Artist Two', helperText: 'Separate values with commas.')),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _saving ? null : _saveProfile,
                  child: Text(_saving ? 'Saving…' : 'Save profile'),
                ),
                const SizedBox(height: 28),
                Text('SECURITY', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                ListTile(
                  leading: const BzSvgIcon(name: 'settings'),
                  title: const Text('Change password'),
                  subtitle: const Text('Sign out of all devices after changing'),
                  trailing: const BzSvgIcon(name: 'chevron-right'),
                  onTap: _saving ? null : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
                  ),
                ),
                const SizedBox(height: 28),
                Text('ACTIVE SESSIONS', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                if (_sessions.isEmpty)
                  const ListTile(title: Text('No active sessions found'))
                else
                  for (final session in _sessions)
                    ListTile(
                      leading: const BzSvgIcon(name: 'smartphone'),
                      title: Text('Session ${(session['id'] as String? ?? '').substring(0, (session['id'] as String? ?? '').length.clamp(0, 8).toInt())}'),
                      subtitle: Text('Created ${session['createdAt'] ?? 'Unknown'} · Expires ${session['expiresAt'] ?? 'Unknown'}'),
                      trailing: TextButton(
                        onPressed: _saving ? null : () => _revoke(session['id'] as String),
                        child: const Text('Revoke'),
                      ),
                    ),
                const SizedBox(height: 28),
                ListTile(
                  leading: const BzSvgIcon(name: 'logout'),
                  title: const Text('Sign out'),
                  subtitle: const Text('This device or all devices'),
                  onTap: _saving ? null : () => confirmBreezzeSignOut(context, ref),
                ),
                OutlinedButton(
                  onPressed: _saving ? null : _deleteAccount,
                  style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  child: const Text('Delete account'),
                ),
              ],
            ),
    );
  }
}
