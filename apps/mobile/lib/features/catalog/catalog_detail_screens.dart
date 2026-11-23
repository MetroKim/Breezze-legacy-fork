import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/bootstrap.dart';
import '../../app/saved_album_store.dart';
import '../../core/audio/playback_source_policy.dart';
import '../../core/audio/youtube_player_handoff.dart';
import '../video/official_music_video_screen.dart';
import '../../core/auth/auth_session.dart';
import '../../core/database/outbox_sync_service.dart';
import '../../features/player/player_controller.dart';
import '../../widgets/bz_brand_icons.dart';

final _artistFollowing = FutureProvider.autoDispose.family<bool, String>((ref, key) {
  ref.watch(authSessionProvider);
  return ref.read(authSessionProvider.notifier).api.artistFollowing(key);
});

final _artistVideos = FutureProvider.autoDispose.family<List<Map>, String>((ref, artist) async {
  final data = await ref.read(authSessionProvider.notifier).api
      .discoveryMusicVideos(query: artist);
  final name = artist.trim().toLowerCase();
  return (data['items'] as List).whereType<Map>().where((item) {
    final id = item['id'];
    final credit = item['artist'];
    return id is String && YoutubePlayerHandoff.isValidProviderTrackId(id) &&
        credit is String && credit.trim().toLowerCase() == name;
  }).take(8).toList();
});

final _artistConcerts = FutureProvider.autoDispose.family<List<Map>, String>((ref, artist) async {
  final territory = ref.watch(outboxTerritoryProvider);
  final data = await ref.read(authSessionProvider.notifier).api.discoveryConcerts(
    country: territory.length == 2 && territory != 'WW' ? territory : 'US',
  );
  final name = artist.trim().toLowerCase();
  return (data['items'] as List).whereType<Map>().where((event) {
    final credit = event['artist'];
    return credit is String &&
        credit.split(', ').any((part) => part.trim().toLowerCase() == name);
  }).toList();
});

final _appleTrackMatchesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, query) async {
  final data = await ref
      .read(authSessionProvider.notifier)
      .api
      .discoveryTrackSearch(query);
  final rawItems = data['items'];
  if (rawItems is! List) return const [];
  return rawItems.whereType<Map>().map((item) =>
      item.map((key, value) => MapEntry(key.toString(), value))).toList();
});

final _appleAlbumTracksProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, albumId) async {
  return ref
      .read(authSessionProvider.notifier)
      .api
      .discoveryAlbumTracks(albumId);
});

/// Track details use only metadata returned by the active search source.
/// The album relationship remains unavailable until a canonical album catalog is connected.
class TrackDetailScreen extends ConsumerWidget {
  final TrackInfo track;
  final List<TrackInfo> relatedTracks;
  final String origin;

  const TrackDetailScreen({
    super.key,
    required this.track,
    this.relatedTracks = const [],
    this.origin = 'search',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artistName = track.artist ?? 'Unknown artist';
    final trackTitle = track.title ?? 'Unknown track';
    final appleTrackMatches = ref.watch(_appleTrackMatchesProvider('$trackTitle $artistName'));
    final artistTracks = relatedTracks
        .where((item) => (item.artist ?? '').trim().toLowerCase() == artistName.trim().toLowerCase())
        .toList();
    final queueTracks = (relatedTracks.isEmpty ? [track] : relatedTracks)
        .where((item) =>
            !isMetadataOnlyTrackId(item.id))
        .toList();
    final queue = [
      for (final item in queueTracks)
        TrackInfo(
          id: item.id,
          title: item.title,
          artist: item.artist,
          artworkUrl: item.artworkUrl,
          duration: item.duration,
        ),
    ];
    final selectedIndex = queueTracks.indexWhere((item) => item.id == track.id);

    Future<void> saveToLibrary() async {
      final auth = ref.read(authSessionProvider);
      final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
      final favorites = ref.read(favoritesStoreProvider);
      if (!await favorites.isFavorite(track.id, ownerId: ownerId)) {
        await favorites.toggle(FavoriteTrack(
          id: track.id,
          title: trackTitle,
          artist: artistName,
          artworkUrl: track.artworkUrl,
          durationMs: track.duration.inMilliseconds,
        ), ownerId: ownerId);
        await ref.read(outboxSyncProvider).drainIfSignedIn();
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library updated')),
      );
    }

    return Scaffold(
      backgroundColor: theme.bzBackground,
      appBar: AppBar(
        title: const Text('Song'),
        leading: IconButton(
          tooltip: 'Back to search',
          icon: const BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: BzAmbientBackdrop(
              // Content is the colour (§1): the artwork blooms softly
              // behind the hero zone while sections below stay on the
              // plain ground.
              artworkUrl: track.artworkUrl,
              child: ListView(
              padding: EdgeInsets.fromLTRB(20, 20, 20, BzBreakpoints.bottomClearance(context, compact: 180)),
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(BzRadius.artwork),
                    child: _TrackArtwork(url: track.artworkUrl, size: 260),
                  ),
                ),
                const SizedBox(height: 22),
                Text(trackTitle, textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(artistName, textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: theme.bzText2)),
                const SizedBox(height: 6),
                Text(
                  track.id.startsWith('bz:')
                      ? 'Track metadata from the connected music source'
                      : 'Track from your Breezze library',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                ),
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: isMetadataOnlyTrackId(track.id)
                          ? null
                          : () async {
                        await ref.read(playerControllerProvider.notifier).playTrack(
                          trackId: track.id,
                          queue: queue,
                          startIndex: selectedIndex < 0 ? 0 : selectedIndex,
                          origin: origin,
                          sourceContext: 'Song details',
                        );
                      },
                      icon: BzSvgIcon(name: 'play', color: theme.bzBackground, size: 18),
                      label: Text(isMetadataOnlyTrackId(track.id)
                          ? 'Playback unavailable' : 'Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed: saveToLibrary,
                      icon: const BzSvgIcon(name: 'plus'),
                      label: const Text('Add to Library'),
                    ),
                    OutlinedButton.icon(
                      onPressed: isMetadataOnlyTrackId(track.id)
                          ? null
                          : () => ref.read(playerControllerProvider.notifier).playNext(
                                TrackInfo(id: track.id, title: track.title, artist: track.artist, artworkUrl: track.artworkUrl, duration: track.duration),
                                origin: origin,
                                sourceContext: 'Song details',
                              ),
                      icon: const BzSvgIcon(name: 'list-music'),
                      label: const Text('Play Next'),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                _CatalogSection(
                  title: 'Artist',
                  subtitle: 'Artist metadata is supplied by the track search result. This is not a verified artist profile.',
                  available: true,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: theme.bzSurface1, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: BzSvgIcon(name: 'mic', color: theme.bzText2, size: 22),
                    ),
                    title: Text(artistName),
                    subtitle: const Text('Open artist page'),
                    trailing: const BzSvgIcon(name: 'chevron-right', size: 18),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ArtistDetailScreen(
                        artist: artistName,
                        savedTracks: const [],
                        searchTracks: [
                          for (final item in artistTracks)
                            FavoriteTrack(
                              id: item.id,
                              title: item.title ?? 'Unknown track',
                              artist: item.artist ?? artistName,
                              artworkUrl: item.artworkUrl,
                              durationMs: item.duration.inMilliseconds,
                            ),
                        ],
                      ),
                    )),
                  ),
                ),
                appleTrackMatches.when(
                  loading: () => _CatalogSection(
                    title: 'Album',
                    subtitle: 'Checking the Apple catalog for an exact track-to-album relationship.',
                    available: true,
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                  error: (_, __) => _CatalogSection(
                    title: 'Album',
                    subtitle: 'The Apple catalog could not verify an album relationship for this track.',
                    available: false,
                  ),
                  data: (matches) {
                    final exact = matches.where((item) {
                      final title = item['title'];
                      final artist = item['artist'];
                      return title is String &&
                          artist is String &&
                          title.trim().toLowerCase() == trackTitle.trim().toLowerCase() &&
                          artist.trim().toLowerCase() == artistName.trim().toLowerCase() &&
                          item['albumId'] != null;
                    }).toList();
                    if (exact.isEmpty) {
                      return _CatalogSection(
                        title: 'Album',
                        subtitle: 'No exact Apple catalog track match was found. Breezze will not infer an album from similar titles or artist names.',
                        available: false,
                      );
                    }
                    final album = exact.first;
                    return _CatalogSection(
                      title: 'Verified album relationship',
                      subtitle: 'Exact title and artist match from Apple iTunes catalog metadata.',
                      available: true,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _TrackArtwork(
                          url: album['artworkUrl'] as String?,
                          size: 56,
                        ),
                        title: Text(album['albumTitle'] as String? ?? 'Unknown album'),
                        subtitle: Text(
                          [
                            if (album['releaseDate'] is String)
                              (album['releaseDate'] as String).split('T').first,
                            'Apple catalog',
                          ].join(' · '),
                        ),
                        trailing: const BzSvgIcon(name: 'arrow-up-right', size: 19),
                        onTap: () {
                          final albumId = album['albumId'];
                          if (albumId == null) return;
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => AppleAlbumCatalogScreen(
                              albumId: albumId.toString(),
                              title: album['albumTitle'] as String? ?? 'Unknown album',
                              artist: album['artist'] as String? ?? artistName,
                              artworkUrl: album['artworkUrl'] as String?,
                              appleUrl: album['albumUrl'] as String?,
                            ),
                          ));
                        },
                      ),
                    );
                  },
                ),
                _CatalogSection(
                  title: 'Track information',
                  subtitle: 'Duration: ' + (track.duration > Duration.zero ? _formatDuration(track.duration) : 'Not provided'),
                  available: true,
                  child: Text('Metadata supplied by the connected catalog.', style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2)),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return duration.inMinutes.toString() + ':' + seconds;
  }
}

/// Artist page for a saved artist. The page is useful immediately for a
/// listener's saved tracks; catalog-only sections stay explicitly unavailable
/// until a canonical artist provider supplies verified metadata.
class ArtistDetailScreen extends ConsumerStatefulWidget {
  final String artist;
  final List<FavoriteTrack> savedTracks;
  final List<FavoriteTrack> searchTracks;
  final String? canonicalArtistId;
  final String? portraitUrl;

  const ArtistDetailScreen({
    super.key,
    required this.artist,
    required this.savedTracks,
    this.searchTracks = const [],
    this.canonicalArtistId,
    this.portraitUrl,
  });

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  List<Map<String, dynamic>> _appleAlbums = [];
  bool _discographyLoading = true;
  String? _discographyError;
  String? _appleArtistId;
  bool _changingFollow = false;

  String get artist => widget.artist;
  List<FavoriteTrack> get savedTracks => widget.savedTracks;
  List<FavoriteTrack> get searchTracks => widget.searchTracks;
  String? get canonicalArtistId => widget.canonicalArtistId;
  String? get portraitUrl => widget.portraitUrl;

  @override
  void initState() {
    super.initState();
    _loadAppleDiscography();
  }

  Future<void> _loadAppleDiscography() async {
    try {
      final api = ref.read(authSessionProvider.notifier).api;
      final search = await api.discoveryArtistSearch(artist);
      final rawArtists = search['items'];
      if (rawArtists is! List) {
        if (mounted) setState(() { _discographyLoading = false; });
        return;
      }
      final normalized = artist.trim().toLowerCase();
      Map? match;
      for (final item in rawArtists.whereType<Map>()) {
        final name = item['name'];
        if (name is String && name.trim().toLowerCase() == normalized) {
          match = item;
          break;
        }
      }
      final id = match?['id'];
      if (id == null) {
        if (mounted) setState(() { _discographyLoading = false; });
        return;
      }
      final result = await api.discoveryArtistAlbums(id.toString());
      final rawAlbums = result['items'];
      if (!mounted) return;
      setState(() {
        _appleArtistId = id.toString();
        _appleAlbums = rawAlbums is List
            ? rawAlbums.whereType<Map>().map((item) =>
                item.map((key, value) => MapEntry(key.toString(), value))).toList()
            : [];
        _discographyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _discographyError = 'Apple artist catalog is temporarily unavailable.';
        _discographyLoading = false;
      });
    }
  }

  Future<void> _openAppleAlbum(Map<String, dynamic> album) async {
    final rawUrl = album['url'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null || uri.scheme != 'https') return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artistKey = canonicalArtistId != null
        ? 'catalog:$canonicalArtistId'
        : _appleArtistId != null ? 'apple:$_appleArtistId' : null;
    final signedIn = ref.watch(authSessionProvider) is AuthSignedIn;
    final following = signedIn && artistKey != null
        ? ref.watch(_artistFollowing(artistKey))
        : null;
    final queue = [for (final track in savedTracks) track.toTrackInfo()];
    final heroArtwork = portraitUrl ?? (searchTracks.isNotEmpty
        ? searchTracks.first.artworkUrl
        : (savedTracks.isNotEmpty ? savedTracks.first.artworkUrl : null));

    return Scaffold(
      backgroundColor: theme.bzBackground,
      appBar: AppBar(
        title: const Text('Artist'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: BzAmbientBackdrop(
              // Artist pages tint from cover art (Apple Music 7.0): the
              // hero blooms from the first available artwork while the
              // tracklist below stays readable on the plain ground.
              artworkUrl: heroArtwork,
              child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
              children: [
                Center(
                  child: ClipOval(
                    child: portraitUrl == null
                        ? Container(
                            width: 156,
                            height: 156,
                            color: theme.bzSurface1,
                            alignment: Alignment.center,
                            child: BzSvgIcon(
                              name: 'mic',
                              size: 54,
                              color: theme.bzText2,
                            ),
                          )
                        : Image.network(
                            portraitUrl!,
                            width: 156,
                            height: 156,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 156,
                              height: 156,
                              color: theme.bzSurface1,
                              alignment: Alignment.center,
                              child: BzSvgIcon(
                                name: 'mic',
                                size: 54,
                                color: theme.bzText2,
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(artist,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  canonicalArtistId != null
                      ? 'Verified artist profile'
                      : savedTracks.isNotEmpty
                          ? 'Artist from your saved music'
                          : 'Artist from track search · not verified',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.bzText2,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: savedTracks.isEmpty
                          ? null
                           : () => ref.read(playerControllerProvider.notifier).playTrack(
                                trackId: savedTracks.first.id,
                                queue: queue,
                                origin: 'library',
                                sourceContext: artist,
                              ),
                      icon: BzSvgIcon(
                        name: 'play',
                        color: theme.bzBackground,
                        size: 18,
                      ),
                      label: const Text('Play saved songs'),
                    ),
                    if (following != null && artistKey != null)
                      following.when(
                        loading: () => const OutlinedButton(
                          onPressed: null, child: Text('Loading…'),
                        ),
                        error: (_, __) => OutlinedButton(
                          onPressed: () => ref.invalidate(_artistFollowing(artistKey)),
                          child: const Text('Retry follow status'),
                        ),
                        data: (active) => OutlinedButton.icon(
                          icon: BzSvgIcon(name: active ? 'check' : 'user-round-plus'),
                          label: Text(active ? 'Following' : 'Follow'),
                          onPressed: _changingFollow ? null : () async {
                            setState(() => _changingFollow = true);
                            try {
                              await ref.read(authSessionProvider.notifier).api
                                  .followArtist(artistKey, !active, name: artist);
                              if (mounted) ref.invalidate(_artistFollowing(artistKey));
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Could not update this artist. Try again.')),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _changingFollow = false);
                            }
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 28),
                _CatalogSection(
                  title: 'Saved Songs',
                  subtitle: 'Songs by this artist that you have saved.',
                  available: savedTracks.isNotEmpty,
                  child: Column(
                    children: [
                      for (var i = 0; i < savedTracks.length; i++)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _TrackArtwork(
                            url: savedTracks[i].artworkUrl,
                            size: 48,
                          ),
                          title: Text(
                            savedTracks[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            savedTracks[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => ref.read(playerControllerProvider.notifier).playTrack(
                            trackId: savedTracks[i].id,
                            queue: queue,
                            startIndex: i,
                            origin: 'library',
                            sourceContext: artist,
                          ),
                        ),
                    ],
                  ),
                ),
                if (searchTracks.isNotEmpty)
                  _CatalogSection(
                    title: 'Tracks found in search',
                    subtitle: 'Matching tracks from the current search results, not a verified complete discography.',
                    available: true,
                    child: Column(
                      children: [
                        for (var i = 0; i < searchTracks.length; i++)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: _TrackArtwork(url: searchTracks[i].artworkUrl, size: 48),
                            title: Text(searchTracks[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(searchTracks[i].artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => ref.read(playerControllerProvider.notifier).playTrack(
                              trackId: searchTracks[i].id,
                              queue: [for (final item in searchTracks) item.toTrackInfo()],
                              startIndex: i,
                              origin: 'search',
                              sourceContext: artist,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_discographyLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_discographyError != null)
                  _CatalogSection(
                    title: 'Apple catalog discography',
                    subtitle: _discographyError!,
                    available: false,
                  )
                else
                  _CatalogSection(
                    title: 'Apple catalog discography',
                    subtitle: _appleArtistId == null
                        ? 'No exact artist match was returned by Apple for this name.'
                        : 'Albums and singles linked to the exact Apple artist record. This is Apple catalog coverage, not a guarantee of every regional release.',
                    available: _appleAlbums.isNotEmpty,
                    child: Column(
                      children: [
                        for (final album in _appleAlbums)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: _TrackArtwork(
                              url: album['artworkUrl'] as String?,
                              size: 52,
                            ),
                            title: Text(
                              album['title'] as String? ?? 'Untitled release',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (album['releaseDate'] is String)
                                  (album['releaseDate'] as String).split('T').first,
                                if (album['trackCount'] is num)
                                  '${(album['trackCount'] as num).toInt()} tracks',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: 'Open release in Apple Music',
                              icon: const BzSvgIcon(name: 'arrow-up-right', size: 19),
                              onPressed: () => _openAppleAlbum(album),
                            ),
                            onTap: () {
                              final albumId = album['id'];
                              if (albumId == null) return;
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => AppleAlbumCatalogScreen(
                                  albumId: albumId.toString(),
                                  title: album['title'] as String? ?? 'Unknown album',
                                  artist: album['artist'] as String? ?? artist,
                                  artworkUrl: album['artworkUrl'] as String?,
                                  appleUrl: album['url'] as String?,
                                ),
                              ));
                            },
                          ),
                      ],
                    ),
                  ),
                ref.watch(_artistVideos(artist)).when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => TextButton.icon(
                    onPressed: () => ref.invalidate(_artistVideos(artist)),
                    icon: const BzSvgIcon(name: 'refresh'),
                    label: const Text('Retry music videos'),
                  ),
                  data: (videos) => _CatalogSection(
                    title: 'Music Videos',
                    subtitle: 'No videos found for this artist.',
                    available: videos.isNotEmpty,
                    child: Column(children: [
                      for (final video in videos)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _TrackArtwork(url: video['artworkUrl'] as String?, size: 52),
                          title: Text(video['title'] as String? ?? 'Music video'),
                          trailing: const BzSvgIcon(name: 'play'),
                          onTap: () async {
                            await ref.read(playerControllerProvider.notifier).pause();
                            if (!context.mounted) return;
                            await Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => OfficialMusicVideoScreen(
                                videoId: video['id'] as String,
                                title: video['title'] as String? ?? 'Music video',
                                artist: artist,
                                artworkUrl: video['artworkUrl'] as String?,
                              ),
                            ));
                          },
                        ),
                    ]),
                  ),
                ),
                ref.watch(_artistConcerts(artist)).when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => _CatalogSection(
                    title: 'Upcoming Concerts',
                    subtitle: '',
                    available: true,
                    child: TextButton(
                      onPressed: () => ref.invalidate(_artistConcerts(artist)),
                      child: const Text('Retry concert listings'),
                    ),
                  ),
                  data: (events) => _CatalogSection(
                    title: 'Upcoming Concerts',
                    subtitle: 'No upcoming shows found in your region.',
                    available: events.isNotEmpty,
                    child: Column(children: [
                      for (final event in events)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const BzSvgIcon(name: 'calendar'),
                          title: Text(event['title'] as String? ?? 'Concert'),
                          subtitle: Text([
                            if (event['date'] is String) (event['date'] as String).split('T').first,
                            if (event['venue'] is String) event['venue'] as String,
                            if (event['city'] is String) event['city'] as String,
                          ].join(' · ')),
                        ),
                      const Text('Concert data provided by JamBase'),
                    ]),
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Metadata-only album detail from Apple's canonical collection and track records.
/// It never turns a preview URL into a full-track playback source.
class AppleAlbumCatalogScreen extends ConsumerWidget {
  final String albumId;
  final String title;
  final String artist;
  final String? artworkUrl;
  final String? appleUrl;

  const AppleAlbumCatalogScreen({
    super.key,
    required this.albumId,
    required this.title,
    required this.artist,
    this.artworkUrl,
    this.appleUrl,
  });

  Future<void> _open(String? rawUrl) async {
    if (rawUrl == null) return;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.scheme != 'https') return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    final savedKey = (ownerId: ownerId, albumId: albumId);
    final isSaved = ref.watch(isAlbumSavedProvider(savedKey));
    final tracks = ref.watch(_appleAlbumTracksProvider(albumId));
    return Scaffold(
      backgroundColor: theme.bzBackground,
      appBar: AppBar(
        title: const Text('Album'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: tracks.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BzSvgIcon(name: 'wifi-off', size: 34),
                      const SizedBox(height: 12),
                      Text('Album catalog unavailable', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text('Apple could not return this album tracklist.', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => ref.invalidate(_appleAlbumTracksProvider(albumId)),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (data) {
                final rawAlbum = data['album'];
                final albumMetadata = rawAlbum is Map
                    ? Map<String, dynamic>.from(rawAlbum)
                    : <String, dynamic>{};
                final albumGenres = albumMetadata['genres'] is List
                    ? (albumMetadata['genres'] as List)
                        .whereType<String>()
                        .where((value) => value.trim().isNotEmpty)
                        .toList(growable: false)
                    : <String>[];
                final isCompilation = albumMetadata['isCompilation'] == true;
                final rawItems = data['items'];
                final items = rawItems is List
                    ? rawItems.whereType<Map>().map((item) =>
                        item.map((key, value) => MapEntry(key.toString(), value))).toList()
                    : <Map<String, dynamic>>[];
                return BzAmbientBackdrop(
                  artworkUrl: artworkUrl,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(20, 18, 20, BzBreakpoints.bottomClearance(context, compact: 180)),
                    children: [
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(BzRadius.artwork),
                          child: artworkUrl == null
                              ? Container(
                                  width: 220,
                                  height: 220,
                                  color: theme.bzSurface1,
                                  alignment: Alignment.center,
                                  child: const BzBnoteMark(size: 72),
                                )
                              : Image.network(
                                  artworkUrl!,
                                  width: 220,
                                  height: 220,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const BzBnoteMark(size: 72),
                                ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 6),
                      Text(artist, textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: theme.bzText2)),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: isSaved.isLoading ? null : () async {
                          try {
                            final wasSaved = isSaved.valueOrNull == true;
                            final store = SavedAlbumStore();
                            if (wasSaved) {
                              await store.remove(ownerId, albumId);
                            } else {
                              await store.save(ownerId, SavedAlbum(
                                id: albumId,
                                title: title,
                                artist: artist,
                                artworkUrl: artworkUrl,
                                catalogUrl: appleUrl,
                                genres: albumGenres,
                                isCompilation: isCompilation,
                                addedAt: DateTime.now().toUtc(),
                              ));
                            }
                            var cloudSynced = false;
                            final active = context.mounted
                                ? ref.read(authSessionProvider)
                                : null;
                            if (auth is AuthSignedIn &&
                                active is AuthSignedIn &&
                                active.userId == ownerId) {
                              try {
                                await store.syncWithCloud(
                                  ownerId,
                                  ref.read(authSessionProvider.notifier).api,
                                  ownerStillActive: () {
                                    if (!context.mounted) return false;
                                    final latest = ref.read(authSessionProvider);
                                    return latest is AuthSignedIn &&
                                        latest.userId == ownerId;
                                  },
                                );
                                cloudSynced = true;
                              } catch (_) {
                                // The durable local outbox retains this exact
                                // add/remove operation for the next reconnect.
                              }
                            }
                            ref.invalidate(isAlbumSavedProvider(savedKey));
                            ref.read(savedAlbumRefreshProvider.notifier).state++;
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(
                                  auth is! AuthSignedIn
                                      ? (wasSaved ? 'Removed from this device'
                                          : 'Saved on this device')
                                      : cloudSynced
                                          ? (wasSaved ? 'Album removed from Library'
                                              : 'Album saved across your devices')
                                          : 'Saved locally. Cloud sync will retry when connected.',
                                )),
                              );
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Could not update saved albums.')),
                              );
                            }
                          }
                        },
                        icon: BzSvgIcon(
                          name: isSaved.valueOrNull == true ? 'check' : 'plus',
                          color: theme.bzBackground,
                        ),
                        label: Text(isSaved.valueOrNull == true
                            ? 'Saved in Library'
                            : 'Add Album to Library'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: appleUrl == null ? null : () => _open(appleUrl),
                        icon: const BzSvgIcon(name: 'arrow-up-right'),
                        label: const Text('Open album in Apple Music'),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.bzSurface1,
                          borderRadius: BorderRadius.circular(BzRadius.card),
                          border: Border.all(color: theme.bzSeparator),
                        ),
                        child: Text(
                          'Verified Apple album tracklist. iTunes preview links, when supplied, are short previews only. Full-track playback inside Breezze requires a separate provider with approved streaming rights.',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text('Tracks • ${items.length}', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      if (items.isEmpty)
                        Text('Apple did not return tracks for this album.', style: theme.textTheme.bodyMedium)
                      else
                        for (var i = 0; i < items.length; i++)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 28,
                              child: Text(
                                (items[i]['trackNumber'] ?? i + 1).toString().padLeft(2, '0'),
                                style: theme.textTheme.labelMedium?.copyWith(color: theme.bzText2),
                              ),
                            ),
                            title: Text(items[i]['title'] as String? ?? 'Unknown track', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              items[i]['durationMs'] is num
                                  ? _formatDuration(Duration(milliseconds: (items[i]['durationMs'] as num).toInt()))
                                  : 'Duration not supplied',
                            ),
                            trailing: IconButton(
                              tooltip: 'Open track in Apple Music',
                              icon: const BzSvgIcon(name: 'arrow-up-right', size: 18),
                              onPressed: () => _open(items[i]['url'] as String?),
                            ),
                          ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Album detail layout. Construct this only from a verified canonical album
/// record; search-result tracks alone are not enough to synthesize an album.
class AlbumDetailScreen extends ConsumerWidget {
  final String canonicalAlbumId;
  final String title;
  final String artist;
  final String? artworkUrl;
  final String? releaseDate;
  final String? recordLabel;
  final List<TrackInfo> tracks;
  final List<String> credits;

  const AlbumDetailScreen({
    super.key,
    required this.canonicalAlbumId,
    required this.title,
    required this.artist,
    required this.tracks,
    this.artworkUrl,
    this.releaseDate,
    this.recordLabel,
    this.credits = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final queue = tracks.where((track) => !isMetadataOnlyTrackId(track.id)).toList();

    Future<void> playAt(int index, {bool shuffle = false}) async {
      if (tracks.isEmpty || index < 0 || index >= tracks.length) return;
      final track = tracks[index];
      if (isMetadataOnlyTrackId(track.id)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This album track has metadata only; native playback is unavailable.')),
        );
        return;
      }
      final queueIndex = queue.indexWhere((item) => item.id == track.id);
      if (queueIndex < 0) return;
      final player = ref.read(playerControllerProvider.notifier);
      await player.playTrack(
        trackId: track.id,
        queue: queue,
        startIndex: queueIndex,
        origin: 'album',
        sourceContext: canonicalAlbumId,
      );
      if (shuffle) player.toggleShuffle();
    }

    Future<void> play({bool shuffle = false}) async {
      if (tracks.isEmpty) return;
      final nativeIndex = tracks.indexWhere((item) => !isMetadataOnlyTrackId(item.id));
      if (nativeIndex >= 0) {
        await playAt(nativeIndex, shuffle: shuffle);
      } else {
        await playAt(0, shuffle: shuffle);
      }
    }

    return Scaffold(
      backgroundColor: theme.bzBackground,
      appBar: AppBar(
        title: const Text('Album'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: BzAmbientBackdrop(
              artworkUrl: artworkUrl,
              child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(BzRadius.artwork),
                    child: _TrackArtwork(
                      url: artworkUrl,
                      size: 250,
                      radius: BzRadius.artwork,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(artist,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.bzText2,
                    )),
                if (releaseDate != null || recordLabel != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    [if (releaseDate != null) releaseDate!, if (recordLabel != null) recordLabel!].join(' · '),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                  ),
                ],
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: queue.isEmpty ? null : () => play(),
                      icon: BzSvgIcon(name: 'play', color: theme.bzBackground, size: 18),
                      label: const Text('Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed: queue.isEmpty ? null : () => play(shuffle: true),
                      icon: const BzSvgIcon(name: 'shuffle'),
                      label: const Text('Shuffle'),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                _CatalogSection(
                  title: 'Tracks',
                  subtitle: 'The verified tracklist for this album.',
                  available: tracks.isNotEmpty,
                  child: Column(
                    children: [
                      for (var i = 0; i < tracks.length; i++)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Text(
                            '${i + 1}'.padLeft(2, '0'),
                            style: theme.textTheme.labelMedium?.copyWith(color: theme.bzText2),
                          ),
                          title: Text(
                            tracks[i].title ?? 'Unknown track',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            tracks[i].artist ?? artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            _duration(tracks[i].duration),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                          ),
                          onTap: () => playAt(i),
                        ),
                    ],
                  ),
                ),
                _CatalogSection(
                  title: 'Credits',
                  subtitle: 'Verified album and track credits.',
                  available: credits.isNotEmpty,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final credit in credits) Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(credit),
                    )],
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  String _duration(Duration duration) {
    if (duration <= Duration.zero) return '';
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _CatalogSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool available;
  final Widget? child;

  const _CatalogSection({
    required this.title,
    required this.subtitle,
    required this.available,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (available && child != null)
            child!
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.bzSurface1,
                borderRadius: BorderRadius.circular(BzRadius.card),
                border: Border.all(color: theme.bzSeparator),
              ),
              child: Row(
                children: [
                  const BzSvgIcon(name: 'info', size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
class _TrackArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;

  const _TrackArtwork({
    required this.url,
    required this.size,
    this.radius = BzRadius.artwork,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? Container(
              width: size,
              height: size,
              color: theme.bzSurface1,
              alignment: Alignment.center,
              child: BzBnoteMark(size: size * 0.3, color: theme.bzText2),
            )
          : Image.network(
              url!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: size,
                height: size,
                color: theme.bzSurface1,
                alignment: Alignment.center,
                child: BzBnoteMark(size: size * 0.3, color: theme.bzText2),
              ),
            ),
    );
  }
}
