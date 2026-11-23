import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/main_tab.dart';
import '../../app/breezze_ui_strings.dart';

import '../../app/bootstrap.dart';
import '../../app/recent_store.dart';
import '../../app/playlist_store.dart';
import '../../core/auth/auth_session.dart';
import '../../widgets/bz_brand_icons.dart';
import '../player/player_controller.dart';
import '../settings/settings_screen.dart';
import '../settings/account_screen.dart';

/// Listen Now home — real rails from persisted history (§03).
///
/// Recently Played comes from the RecentStore; Favorites from the
/// FavoritesStore. No placeholder data presented as real (§50.1).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _recent = RecentStore();
  List<RecentEntry> _recentlyPlayed = [];
  List<FavoriteTrack> _favorites = [];
  List<TrackInfo> _madeForYou = [];
  List<TrackInfo> _fromFollowedArtists = [];
  Map<String, dynamic>? _replay;
  bool _loading = true;
  int _refreshVersion = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final version = ++_refreshVersion;
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    final recent = await _recent.load(ownerId: ownerId);
    if (!mounted || version != _refreshVersion) return;
    final favorites = await ref.read(favoritesStoreProvider).load(ownerId: ownerId);
    Map<String, dynamic>? replay;
    var madeForYou = <TrackInfo>[];
    var followedTracks = <TrackInfo>[];
    if (!mounted || version != _refreshVersion) return;
    if (auth is AuthSignedIn) {
      final api = ref.read(authSessionProvider.notifier).api;
      try {
        final sections = await api.homeFeed();
        // Keep the Home shelves distinct while resolving real canonical
        // metadata. Each failed catalog item is omitted, never faked.
        Future<List<TrackInfo>> resolveShelf(String sectionType) async {
          Map<String, dynamic>? section;
          for (final candidate in sections) {
            if (candidate['sectionType'] == sectionType) {
              section = candidate;
              break;
            }
          }
          final ids = section?['trackIds'];
          final trackIds = ids is List
              ? ids.whereType<String>().where((id) => id.isNotEmpty)
                  .take(12).toList(growable: false)
              : <String>[];
          final resolved = await Future.wait(trackIds.map((id) async {
            try {
              final song = await api.catalogSong(id);
              final artistData = song['artist'];
              final duration = song['duration'];
              return TrackInfo(
                id: song['id'] as String? ?? id,
                title: song['title'] as String? ?? '',
                artist: artistData is Map
                    ? artistData['name'] as String? ?? ''
                    : '',
                artworkUrl: song['artworkUrl'] as String?,
                duration: Duration(
                  seconds: duration is num ? duration.toInt() : 0,
                ),
              );
            } catch (_) {
              return null;
            }
          }));
          return resolved.whereType<TrackInfo>()
              .where((track) => track.title?.isNotEmpty == true)
              .toList(growable: false);
        }
        final shelves = await Future.wait([
          resolveShelf('followed_artists'),
          resolveShelf('personalized'),
        ]);
        followedTracks = shelves[0];
        madeForYou = shelves[1];
      } catch (_) {
            // A track can become unavailable between ranking and display.
            return null;
          }
        }));
        madeForYou = resolved.whereType<TrackInfo>()
            .where((track) => track.title?.isNotEmpty == true)
            .toList(growable: false);
      } catch (_) {
        // Personalized content is optional; local listening history remains.
      }
      try {
        replay = await api.replaySummary();
      } catch (_) {
        // Replay is an independent home section.
      }
    }
    if (!mounted || version != _refreshVersion) return;
    final currentAuth = ref.read(authSessionProvider);
    final currentOwnerId =
        currentAuth is AuthSignedIn ? currentAuth.userId : 'guest';
    if (currentOwnerId != ownerId) return;
    setState(() {
      _recentlyPlayed = recent;
      _favorites = favorites;
      _madeForYou = madeForYou;
      _fromFollowedArtists = followedTracks;
      _replay = replay;
      _loading = false;
    });
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    String? remoteId;
    if (auth is AuthSignedIn) {
      try {
        final remote = await ref.read(authSessionProvider.notifier).api.createPlaylist(name.trim());
        remoteId = remote['id'] as String?;
      } catch (_) {}
    }
    await PlaylistStore().create(ownerId, name, id: remoteId);
    if (!mounted) return;
    ref.read(homeTabHintProvider.notifier).state = MainTab.library.index;
    ref.read(playlistRefreshSignalProvider.notifier).state++;
  }

  void _play(TrackInfo track, List<TrackInfo> queue, int index) {
    ref.read(playerControllerProvider.notifier).playTrack(
          trackId: track.id,
          queue: queue,
          startIndex: index,
          origin: 'home',
          sourceContext: 'Listen Now',
        );
  }

  /// Time-based greeting from the local clock; no network dependency.
  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Good late night';
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    if (hour < 21) return 'Good evening';
    return 'Good night';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      final before = previous is AuthSignedIn ? previous.userId : null;
      final after = next is AuthSignedIn ? next.userId : null;
      if (before == after) return;
      setState(() {
        _recentlyPlayed = [];
        _favorites = [];
        _madeForYou = [];
        _replay = null;
        _loading = true;
      });
      _refresh();
    });
    final theme = Theme.of(context);
    final shortcuts = <String, TrackInfo>{};
    for (final r in _recentlyPlayed) {
      if (shortcuts.length >= 6) break;
      shortcuts[r.id] = TrackInfo(id: r.id, title: r.title, artist: r.artist, artworkUrl: r.artworkUrl, duration: r.duration);
    }

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 24, 16, BzBreakpoints.bottomClearance(context, compact: 220)),
        children: [
          Row(
            children: [
              BzRibbonLogo(width: 96, color: theme.bzText1),
              const Spacer(),
              IconButton(
                tooltip: 'Create playlist',
                onPressed: _createPlaylist,
                icon: SvgPicture.asset(
                  'assets/icons/plus.svg',
                  width: 21,
                  height: 21,
                  colorFilter: ColorFilter.mode(
                    theme.bzAccent,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More options',
                icon: BzSvgIcon(name: 'more-vertical', color: theme.bzText1),
                onSelected: (value) {
                  if (value == 'settings') {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SettingsScreen(),
                      ),
                    );
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'settings',
                    child: Text('Settings'),
                  ),
                ],
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const AccountScreen(),
                    ),
                  ),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: theme.bzSurface1,
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.bzSeparator),
                    ),
                    alignment: Alignment.center,
                    child: SvgPicture.asset(
                      'assets/icons/profile.svg',
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        theme.bzText1,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Hero greeting (§4.1): time-based, local only.
          Text(_greeting, style: theme.textTheme.displayMedium),
          const SizedBox(height: 24),
          if (_loading) ...[
            const BzSkeleton(width: 172, height: 16, radius: 5),
            const SizedBox(height: 16),
            for (var i = 0; i < 3; i++) ...[
              const BzSkeletonTrackRow(),
              const SizedBox(height: 14),
            ],
            const SizedBox(height: 18),
            const BzSkeletonArtworkGrid(itemCount: 4),
          ],
          if (!_loading && shortcuts.isNotEmpty) ...[
            _ShortcutGrid(tracks: shortcuts.values.toList(), onPlay: _play),
            const SizedBox(height: 28),
          ],
          if (!_loading && _fromFollowedArtists.isNotEmpty) ...[
            _Rail(
              title: breezzeText(Localizations.localeOf(context).languageCode, 'From Artists You Follow'),
              tracks: _fromFollowedArtists,
              onPlay: _play,
            ),
            const SizedBox(height: 24),
          ],
          if (!_loading && _madeForYou.isNotEmpty) ...[
            _Rail(
              title: breezzeText(Localizations.localeOf(context).languageCode, 'Made for You'),
              tracks: _madeForYou,
              onPlay: _play,
            ),
            const SizedBox(height: 24),
          ],
          if (!_loading && _recentlyPlayed.isNotEmpty) ...[
            _Rail(
              title: 'Recently Played',
              tracks: [
                for (final r in _recentlyPlayed)
                  TrackInfo(
                    id: r.id,
                    title: r.title,
                    artist: r.artist,
                    artworkUrl: r.artworkUrl,
                    duration: r.duration,
                  )
              ],
              onPlay: _play,
            ),
            const SizedBox(height: 24),
          ],
          if (!_loading && (_recentlyPlayed.isNotEmpty || _favorites.isNotEmpty)) ...[
            _Rail(
              title: 'Your Mix',
              tracks: [
                ..._recentlyPlayed.map((r) => TrackInfo(id: r.id, title: r.title, artist: r.artist, artworkUrl: r.artworkUrl, duration: r.duration)),
                ..._favorites.map((f) => f.toTrackInfo()).where((f) => !_recentlyPlayed.any((r) => r.id == f.id)),
              ],
              onPlay: _play,
            ),
            const SizedBox(height: 24),
          ],
          if (!_loading && _favorites.isNotEmpty) ...[
            _Rail(
              title: 'Your Favorites',
              tracks: [
                for (final f in _favorites)
                  f.toTrackInfo()
              ],
              onPlay: _play,
            ),
            const SizedBox(height: 24),
          ],
          if (!_loading && _recentlyPlayed.isEmpty && _favorites.isEmpty)
            _FirstRunCard(
              onSearch: () => ref.read(homeTabHintProvider.notifier).state = MainTab.search.index,
            ),
          if (_replay != null && ((_replay!['totalPlays'] as num?)?.toInt() ?? 0) > 0)
            _ReplayCard(summary: _replay!),
        ],
      ),
      ),
    );
  }
}

/// Hint provider: tapping the first-run card can nudge the shell to the
/// Search tab (the shell reads this provider's value when building).
final homeTabHintProvider = StateProvider<int>((ref) => 0);

/// Shortcut tile grid (§4.1 section 2): up to 6 recently played items as
/// compact chips — artwork, title, artist on surface1 cards. Real
/// history only; nothing fabricated.
class _ShortcutGrid extends StatelessWidget {
  final List<TrackInfo> tracks;
  final void Function(TrackInfo, List<TrackInfo>, int) onPlay;

  const _ShortcutGrid({required this.tracks, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 2 columns compact, 3 medium, 4+ wide (Apple Music grid density).
        final width = constraints.maxWidth;
        final columns = width >= 1080 ? 4 : width >= 620 ? 3 : 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < tracks.length; i++)
              _ShortcutTile(
                track: tracks[i],
                width: (width - 10 * (columns - 1)) / columns,
                onTap: () => onPlay(tracks[i], tracks, i),
              ),
          ],
        );
      },
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  final TrackInfo track;
  final double width;
  final VoidCallback onTap;

  const _ShortcutTile({
    required this.track,
    required this.width,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Play ${track.title ?? 'track'}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: width,
          height: 64,
          decoration: BoxDecoration(
            color: theme.bzSurface1,
            borderRadius: BorderRadius.circular(BzRadius.button),
            border: Border.all(color: theme.bzSeparator),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(BzRadius.button),
                ),
                child: track.artworkUrl != null
                    ? Image.network(
                        track.artworkUrl!,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 64,
                          height: 64,
                          color: theme.bzSurface2,
                          alignment: Alignment.center,
                          child: BzBnoteMark(size: 26, color: theme.bzText2),
                        ),
                      )
                    : Container(
                        width: 64,
                        height: 64,
                        color: theme.bzSurface2,
                        alignment: Alignment.center,
                        child: BzBnoteMark(size: 26, color: theme.bzText2),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title ?? 'Unknown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: BzType.footnote,
                        fontWeight: FontWeight.w600,
                        color: theme.bzText1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: BzType.caption,
                        color: theme.bzText2,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: BzSvgIcon(name: 'play', size: 16, color: theme.bzText2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal content rail with real tracks (§3.2).
class _Rail extends StatelessWidget {
  final String title;
  final List<TrackInfo> tracks;
  final void Function(TrackInfo, List<TrackInfo>, int) onPlay;

  const _Rail({required this.title, required this.tracks, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(title,
              style: TextStyle(
                  fontSize: BzType.title3,
                  fontWeight: FontWeight.w600,
                  color: theme.bzText1)),
        ),
        SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: tracks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final track = tracks[i];
              return _TrackCard(
                track: track,
                onTap: () => onPlay(track, tracks, i),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Track card — artwork, title, artist (§3.2 card anatomy).
/// Press feedback: scale 0.96 spring (§5.2). Reduced motion collapses
/// to the resting state instantly.
class _TrackCard extends StatefulWidget {
  final TrackInfo track;
  final VoidCallback onTap;

  const _TrackCard({required this.track, required this.onTap});

  @override
  State<_TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<_TrackCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = widget.track;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: BzMotion.fastMs),
        curve: Curves.easeOut,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: theme.bzSurface2,
                borderRadius: BorderRadius.circular(BzRadius.artwork),
                border: Border.all(color: theme.bzSeparator),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(BzRadius.artwork),
                child: track.artworkUrl != null
                    ? Image.network(
                        track.artworkUrl!,
                        width: 150,
                        height: 150,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Center(
                          child:
                              BzBnoteMark(size: 48, color: theme.bzText2),
                        ),
                      )
                    : Center(
                        child:
                            BzBnoteMark(size: 48, color: theme.bzText2),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(track.title ?? 'Unknown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: BzType.headline,
                    fontWeight: FontWeight.w600,
                    color: theme.bzText1)),
            Text(track.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: BzType.footnote, color: theme.bzText2)),
          ],
        ),
      ),
    );
  }
}

/// First-run card — the honest empty state pointing to Search.
class _FirstRunCard extends StatelessWidget {
  final VoidCallback onSearch;

  const _FirstRunCard({required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.bzSurface1,
        borderRadius: BorderRadius.circular(BzRadius.card),
        border: Border.all(color: theme.bzSeparator),
      ),
      child: Column(
        children: [
          BzBnoteMark(size: 56, color: theme.bzText2),
          const SizedBox(height: 16),
          Text('Find your first song', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('The music you play appears in Recently Played.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onSearch,
            icon: BzSvgIcon(name: 'search', size: 18, color: theme.colorScheme.onPrimary),
            label: const Text('Search music'),
          ),
        ],
      ),
    );
  }
}


class _ReplayCard extends StatelessWidget {
  const _ReplayCard({required this.summary});
  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final songs = summary['topSongIds'] is List
        ? (summary['topSongIds'] as List).whereType<Map>().toList()
        : const <Map>[];
    final artists = summary['topArtistIds'] is List
        ? (summary['topArtistIds'] as List).whereType<Map>().toList()
        : const <Map>[];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.bzSurface1,
        borderRadius: BorderRadius.circular(BzRadius.card),
        border: Border.all(color: theme.bzSeparator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('YOUR REPLAY', style: theme.textTheme.labelSmall?.copyWith(
            color: theme.bzText2, letterSpacing: 1, fontWeight: FontWeight.w700,
          )),
          const SizedBox(height: 8),
          Text('${summary['totalPlays'] ?? 0} plays',
              style: theme.textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (songs.isNotEmpty) ...[
            Text('TOP SONGS', style: theme.textTheme.labelSmall),
            for (final song in songs.take(3))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(song['title'] as String? ?? 'Track'),
                subtitle: Text(song['artist'] as String? ?? ''),
                trailing: Text('${song['plays'] ?? 0}'),
              ),
          ],
          if (artists.isNotEmpty) ...[
            Text('TOP ARTISTS', style: theme.textTheme.labelSmall),
            for (final artist in artists.take(3))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(artist['name'] as String? ?? 'Artist'),
                trailing: Text('${artist['plays'] ?? 0}'),
              ),
          ],
        ],
      ),
    );
  }
}
