import 'package:material_ui/material_ui.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_session.dart';
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authSessionProvider.notifier).api;
      final profile = await api.profile();
      if (!mounted) return;
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
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
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

  Future<void> _signOutEverywhere() async {
    setState(() { _saving = true; _error = null; });
    try {
      await ref.read(authSessionProvider.notifier).signOutEverywhere();
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not revoke remote sessions. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Text('ACCOUNT SECURITY', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                const Text('Your Google, Apple, or email identity is secured '
                    'by Supabase Auth. Breezze does not store your password.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _saving ? null : _signOutEverywhere,
                  child: const Text('Sign out on all devices'),
                ),
                const SizedBox(height: 12),
                Text(
                  'For account deletion, contact Breezze Support while '
                  'the secure deletion flow is being integrated.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
