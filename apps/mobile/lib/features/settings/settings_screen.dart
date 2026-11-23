import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/download_preferences.dart';
import '../../app/appearance_controller.dart';
import '../../app/search_history_store.dart';
import '../../core/auth/auth_session.dart';
import 'account_screen.dart';
import '../authentication/auth_screen.dart';
import 'help_support_screen.dart';
import '../notifications/notifications_screen.dart';
import '../player/sleep_timer_controller.dart';
import '../../widgets/bz_brand_icons.dart';

/// Settings — audio quality, playback, downloads, account (§19).
/// Breezze is fully free: no membership or upgrade UI anywhere.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _store = DownloadPreferencesStore();
  DownloadPreferences _downloads = const DownloadPreferences();
  var _preferencesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadDownloadPreferences();
  }

  Future<void> _loadDownloadPreferences() async {
    final value = await _store.load();
    if (!mounted) return;
    setState(() {
      _downloads = value;
      _preferencesLoaded = true;
    });
  }

  Future<void> _saveDownloadPreferences(DownloadPreferences value) async {
    setState(() => _downloads = value);
    await _store.save(value);
  }

  Future<void> _configureSleepTimer() async {
    final active = ref.read(sleepTimerProvider);
    final minutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sleep timer'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in [15, 30, 45, 60, 90])
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(value),
                child: Text(value.toString() + ' min'),
              ),
          ],
        ),
        actions: [
          if (active != null)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(-1),
              child: const Text('Turn off timer'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || minutes == null) return;
    final timer = ref.read(sleepTimerProvider.notifier);
    if (minutes == -1) {
      timer.cancel();
      return;
    }
    timer.schedule(Duration(minutes: minutes));
  }
  Future<void> _clearSearchHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear search history?'),
        content: const Text('Recent searches saved on this device will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await SearchHistoryStore().clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Search history cleared')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = ref.watch(authSessionProvider);
    final email = auth is AuthSignedIn ? auth.email : null;
    final sleepTimerEndsAt = ref.watch(sleepTimerProvider);

    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 24, 16, BzBreakpoints.bottomClearance(context, compact: 220)),
        children: [
          Text('Settings', style: theme.textTheme.displayMedium),
          const SizedBox(height: 16),
          _section(theme, 'Account', [
            ListTile(
              leading: BzBnoteMark(size: 28, color: theme.bzText1),
              title: Text(email ?? 'Your music, your way'),
              subtitle: Text(email == null
                  ? 'Sign in to sync your library across devices'
                  : 'Breezze — free for everyone',
                  style: theme.textTheme.bodySmall),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => email == null
                      ? const AuthScreen(popOnSignIn: true)
                      : const AccountScreen(),
                ),
              ),
            ),
            ListTile(
              leading: BzSvgIcon(name: 'user-round'),
              title: Text(email == null ? 'Sign in or create an account'
                  : 'Account details and sessions'),
              trailing: BzSvgIcon(name: 'chevron-right', color: theme.bzText2),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => email == null
                      ? const AuthScreen(popOnSignIn: true)
                      : const AccountScreen(),
                ),
              ),
            ),
            ListTile(
              leading: BzSvgIcon(name: 'bell'),
              title: const Text('Notifications'),
              trailing: BzSvgIcon(name: 'chevron-right', color: theme.bzText2),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotificationsScreen()),
              ),
            ),
            if (email != null)
            ListTile(
              leading: BzSvgIcon(name: 'logout'),
              title: const Text('Sign out'),
              onTap: () {
                ref.read(authSessionProvider.notifier).signOut();
              },
            ),
          ]),
          _section(theme, 'Audio Quality', [
            if (!_preferencesLoaded)
              const Padding(
                padding: EdgeInsets.all(12),
                child: BzSkeletonTrackRow(),
              )
            else ...[
              ListTile(
                title: const Text('Streaming quality'),
                trailing: DropdownButton<String>(
                  value: _downloads.streamingQuality,
                  items: const [
                    DropdownMenuItem(value: 'AAC_128', child: Text('Standard')),
                    DropdownMenuItem(value: 'AAC_256', child: Text('High')),
                    DropdownMenuItem(value: 'LOSSLESS', child: Text('Lossless')),
                    DropdownMenuItem(value: 'HI_RES', child: Text('Hi-Res')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _saveDownloadPreferences(_downloads.copyWith(streamingQuality: value));
                    }
                  },
                ),
              ),
              ListTile(
                title: const Text('Offline download quality'),
                trailing: DropdownButton<String>(
                  value: _downloads.quality,
                  items: const [
                    DropdownMenuItem(value: 'standard', child: Text('Standard')),
                    DropdownMenuItem(value: 'lossless', child: Text('Lossless')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _saveDownloadPreferences(_downloads.copyWith(quality: value));
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'The backend selects only a format your territory and provider rights allow. Offline quality is a preference, not a guarantee of an available lossless file.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                ),
              ),
            ],
          ]),
          _section(theme, 'Downloads', [
            if (!_preferencesLoaded)
              const Padding(
                padding: EdgeInsets.all(12),
                child: BzSkeletonTrackRow(),
              )
            else ...[
              SwitchListTile(
                value: _downloads.wifiOnly,
                onChanged: (value) => _saveDownloadPreferences(
                  _downloads.copyWith(
                    wifiOnly: value,
                    allowCellular: value ? false : _downloads.allowCellular,
                  ),
                ),
                title: const Text('Download over Wi-Fi only'),
                dense: true,
              ),
              SwitchListTile(
                value: _downloads.allowCellular,
                onChanged: (value) => _saveDownloadPreferences(
                  _downloads.copyWith(
                    allowCellular: value,
                    wifiOnly: value ? false : _downloads.wifiOnly,
                  ),
                ),
                title: const Text('Allow cellular downloads'),
                dense: true,
              ),
              SwitchListTile(
                value: _downloads.autoCleanup,
                onChanged: (value) => _saveDownloadPreferences(
                  _downloads.copyWith(autoCleanup: value),
                ),
                title: const Text('Automatic storage cleanup'),
                dense: true,
              ),
              ListTile(
                title: const Text('Minimum free storage'),
                trailing: DropdownButton<int>(
                  value: _downloads.minimumFreeSpaceGb,
                  items: const [1, 2, 5, 10]
                      .map((gb) => DropdownMenuItem(
                            value: gb,
                            child: Text('$gb GB'),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      _saveDownloadPreferences(
                        _downloads.copyWith(minimumFreeSpaceGb: value),
                      );
                    }
                  },
                ),
              ),
              ListTile(
                title: const Text('Offline download quality'),
                trailing: DropdownButton<String>(
                  value: _downloads.quality,
                  items: const [
                    DropdownMenuItem(
                      value: 'standard',
                      child: Text('Standard'),
                    ),
                    DropdownMenuItem(
                      value: 'lossless',
                      child: Text('Lossless'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _saveDownloadPreferences(
                        _downloads.copyWith(quality: value),
                      );
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Quality options depend on the audio rights and formats '
                  'available from the authorized provider.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.bzText2,
                  ),
                ),
              ),
            ],
          ]),
          _section(theme, 'Playback', [
            const ListTile(
              leading: BzSvgIcon(name: 'repeat'),
              title: Text('Gapless playback'),
              subtitle: Text('Requires an audio-engine capability that is not available yet.'),
              enabled: false,
            ),
            const ListTile(
              leading: BzSvgIcon(name: 'volume-2'),
              title: Text('Crossfade and volume normalization'),
              subtitle: Text('Playback transitions and normalization are not exposed by the current engine.'),
              enabled: false,
            ),
            const ListTile(
              leading: BzSvgIcon(name: 'infinity'),
              title: Text('Autoplay similar music'),
              subtitle: Text('Available when Breezze recommendations are connected.'),
              enabled: false,
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'clock'),
              title: const Text('Sleep timer'),
              subtitle: Text(
                sleepTimerEndsAt == null
                    ? 'Pause playback after a set time.'
                    : 'Playback will pause at ' + TimeOfDay.fromDateTime(sleepTimerEndsAt).format(context) + '.',
              ),
              trailing: sleepTimerEndsAt == null
                  ? const BzSvgIcon(name: 'chevron-right')
                  : TextButton(
                      onPressed: () => ref.read(sleepTimerProvider.notifier).cancel(),
                      child: const Text('Turn off'),
                    ),
              onTap: _configureSleepTimer,
            ),
          ]),
          _section(theme, 'Appearance & Accessibility', [
            ListTile(
              leading: const BzSvgIcon(name: 'moon'),
              title: const Text('Appearance'),
              trailing: DropdownButton<ThemeMode>(
                value: ref.watch(appearanceProvider).valueOrNull ?? ThemeMode.system,
                items: const [
                  DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: ref.watch(appearanceProvider).isLoading ? null : (mode) async {
                  if (mode == null) return;
                  try {
                    await ref.read(appearanceProvider.notifier).select(mode);
                  } catch (_) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not save appearance. Try again.')),
                    );
                  }
                },
              ),
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'settings'),
              title: const Text('Motion and transparency'),
              subtitle: const Text('Breezze respects system reduced-motion and high-contrast settings.'),
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'globe'),
              title: const Text('App language'),
              subtitle: const Text('Uses your device language until localized translations are available.'),
            ),
          ]),
          _section(theme, 'Privacy & Data', [
            ListTile(
              leading: const BzSvgIcon(name: 'history'),
              title: const Text('Clear search history'),
              subtitle: const Text('Remove recent searches stored on this device.'),
              trailing: const BzSvgIcon(name: 'chevron-right'),
              onTap: _clearSearchHistory,
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'trash'),
              title: const Text('Clear artwork cache'),
              subtitle: const Text('Free memory used by album artwork.'),
              onTap: () {
                PaintingBinding.instance.imageCache.clear();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Artwork cache cleared.')),
                );
              },
            ),
          ]),
          _section(theme, 'Help & Support', [
            ListTile(
              leading: const BzSvgIcon(name: 'bell'),
              title: const Text('Notifications'),
              subtitle: const Text('Review account and service updates.'),
              trailing: const BzSvgIcon(name: 'chevron-right'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotificationsScreen()),
              ),
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'help-circle'),
              title: const Text('Help centre'),
              subtitle: const Text('Playback, downloads, account and privacy answers.'),
              trailing: const BzSvgIcon(name: 'chevron-right'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HelpSupportScreen()),
              ),
            ),
            ListTile(
              leading: const BzSvgIcon(name: 'share'),
              title: const Text('Send feedback'),
              subtitle: const Text('Share feedback with the Breezze team.'),
              trailing: const BzSvgIcon(name: 'chevron-right'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HelpSupportScreen()),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text(title.toUpperCase(),
              style: TextStyle(
                  fontSize: BzType.footnote,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: theme.bzText2)),
        ),
        Container(
          decoration: BoxDecoration(
            color: theme.bzSurface1,
            borderRadius: BorderRadius.circular(BzRadius.card),
            border: Border.all(color: theme.bzSeparator),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}