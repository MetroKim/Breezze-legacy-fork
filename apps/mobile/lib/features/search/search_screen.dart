import '../free_music/device_audio.dart';
import '../video/device_video.dart';
import '../player/now_playing_screen.dart';
import 'dart:async';

import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../video/open_youtube_player.dart';
import '../../core/audio/playback_source_policy.dart';

import '../../app/bootstrap.dart';
import '../../app/downloads_controller.dart';
import '../../app/search_history_store.dart';
import '../../app/playlist_store.dart';
import '../catalog/catalog_detail_screens.dart';
import '../../core/auth/auth_session.dart';
import '../../core/database/outbox_sync_service.dart';
import '../player/player_controller.dart';
import '../../widgets/bz_brand_icons.dart';

/// Search screen — real results from the live source, with local recent
/// searches and live download progress.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final Map<String, SearchHistoryStore> _historyStores = {};
  List<BzTrack> _results = [];
  List<String> _recentSearches = [];
  var _loading = false;
  var _searched = false;
  var _searchLibrary = false;
  var _searchVideos = false;
  String? _error;

  static const _suggestedSearches = <String, String>{
    'Latest Songs': 'new songs',
    'New Releases': 'new music releases',
    'Trending Songs': 'trending songs',
    'Daily Top 100': 'top 100 songs',
    'Coming Soon': 'upcoming albums',
    'Music Videos': 'music videos',
    'Charts': 'top music charts',
    'Browse by Genre': 'Afrobeats',
    'Moods & Activities': 'workout music',
    'Concerts': 'upcoming concerts',
    'City Charts': 'top city charts',
  };
  int _searchGeneration = 0;
  Timer? _typeaheadTimer;

  SearchHistoryStore get _history {
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    return _historyStores.putIfAbsent(
      ownerId,
      () => SearchHistoryStore(ownerId: ownerId),
    );
  }


  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _typeaheadTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final auth = ref.read(authSessionProvider);
      final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
      final history = await _history.load();
      if (!mounted) return;
      final current = ref.read(authSessionProvider);
      final currentOwner = current is AuthSignedIn ? current.userId : 'guest';
      if (ownerId != currentOwner) return;
      setState(() => _recentSearches = history);
    } catch (_) {
      // Search must remain usable when local history storage is unavailable.
    }
  }

  void _onQueryChanged(String query) {
    _typeaheadTimer?.cancel();
    _searchGeneration++;
    final normalized = query.trim();
    setState(() {
      _loading = normalized.length >= 2;
      _searched = normalized.length >= 2;
      _results = [];
      _error = null;
    });
    if (normalized.length < 2) return;
    _typeaheadTimer = Timer(const Duration(milliseconds: 500), () {
      _search(normalized, recordHistory: false);
    });
  }

  Future<void> _search(String query, {bool recordHistory = true}) async {
    _typeaheadTimer?.cancel();
    final normalized = query.trim();
    if (normalized.isEmpty) return;

    final generation = ++_searchGeneration;
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
    });

    // Search history is best-effort local UI state. A disk failure must not
    // prevent the actual catalogue search or masquerade as a provider outage.
    if (recordHistory) {
      try {
        final history = await _history.add(normalized);
        if (mounted && generation == _searchGeneration) {
          setState(() => _recentSearches = history);
        }
      } catch (_) {
        // Continue with the music-source request even if persistence fails.
      }
    }

    if (!mounted || generation != _searchGeneration) return;

    if (_searchLibrary) {
      try {
        final auth = ref.read(authSessionProvider);
        final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
        final favorites = await ref.read(favoritesStoreProvider).load(ownerId: ownerId);
        if (!mounted || generation != _searchGeneration) return;
        final needle = normalized.toLowerCase();
        final matches = favorites.where((item) =>
            item.title.toLowerCase().contains(needle) ||
            item.artist.toLowerCase().contains(needle));
        setState(() {
          _loading = false;
          _results = [
            for (final item in matches)
              BzTrack(
                id: item.id,
                title: item.title,
                artist: item.artist,
                artworkUrl: item.artworkUrl,
                duration: Duration(milliseconds: item.durationMs),
              ),
          ];
        });
      } catch (_) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _loading = false;
          _results = [];
          _error = 'Your library could not be searched right now.';
        });
      }
      return;
    }

    try {
      final isVideoSearch = _searchVideos && !_searchLibrary;
      if (isVideoSearch) {
        // The video discovery endpoint only returns YouTube Music's
        // Original Music Video classification, not UGC or static-art tracks.
        final data = await ref.read(authSessionProvider.notifier).api
            .discoveryMusicVideos(query: normalized.toLowerCase() == 'music videos'
                ? 'official music video'
                : normalized);
        final rawItems = data['items'];
        final videos = rawItems is List ? rawItems.whereType<Map>() : const <Map>[];
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _loading = false;
          _results = videos.map((item) {
            final id = item['id'] as String? ?? '';
            final duration = item['durationSec'];
            return BzTrack(
              id: 'bzv:$id',
              title: item['title'] as String? ?? 'Untitled video',
              artist: item['artist'] as String? ?? 'Unknown artist',
              artworkUrl: item['artworkUrl'] as String?,
              duration: Duration(seconds: duration is num ? duration.toInt() : 0),
            );
          }).where((track) => track.id.length > 9).toList();
        });
      } else {
        final op = await ref.read(catalogSourceProvider).search(normalized);
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _loading = false;
          _results = [if (op is ProviderOk<List<ProviderTrack>>) ...op.value
                  .map((track) => BzTrack(
                        id: track.breezzeTrackId,
                        hasPreview: track.hasPreview,
                        title: track.title,
                        artist: track.artist,
                        artworkUrl: track.artworkUrl,
                        duration: track.duration,
                      ))
                  ];
          if (_results.isEmpty && op is! ProviderOk<List<ProviderTrack>>) {
            _error = 'Search could not be completed. Try again in a moment.';
          }
        });
      }
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _loading = false;
        _results = [];
        if (_results.isEmpty) _error = 'Could not reach the music source. Check your connection.';
      });
    }
  }

  Future<void> _removeHistory(String query) async {
    final history = await _history.remove(query);
    if (!mounted) return;
    setState(() => _recentSearches = history);
  }

  Future<void> _clearHistory() async {
    await _history.clear();
    if (!mounted) return;
    setState(() => _recentSearches = []);
  }

  void _reuseSearch(String query) {
    if (query.trim().toLowerCase() == 'music videos') {
      setState(() {
        _searchVideos = true;
        _searchLibrary = false;
      });
    }
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    _search(query);
  }

  Future<String?> _requestPlaylistName() async {
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
    return name?.trim().isEmpty == true ? null : name?.trim();
  }

  Future<void> _showAddToPlaylist(BzTrack track) async {
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    final store = PlaylistStore();
    var playlists = await store.load(ownerId);
    String? selectedId;

    Future<String?> create(String name) async {
      String? remoteId;
      if (auth is AuthSignedIn) {
        try {
          final remote = await ref.read(authSessionProvider.notifier).api.createPlaylist(name);
          remoteId = remote['id'] as String?;
        } catch (_) {}
      }
      await store.create(ownerId, name, id: remoteId);
      return remoteId;
    }

    if (playlists.isEmpty) {
      final name = await _requestPlaylistName();
      if (name == null || name.isEmpty) return;
      await create(name);
      playlists = await store.load(ownerId);
      if (playlists.isNotEmpty) selectedId = playlists.first.id;
    } else {
      selectedId = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('Add to Playlist', style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final playlist in playlists)
                ListTile(
                  leading: BzBnoteMark(size: 40, color: Theme.of(context).bzText2),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.tracks.length} songs'),
                  onTap: () => Navigator.of(context).pop(playlist.id),
                ),
              ListTile(
                leading: BzSvgIcon(name: 'plus', color: Theme.of(context).bzAccent),
                title: const Text('New Playlist'),
                onTap: () => Navigator.of(context).pop('__new__'),
              ),
            ],
          ),
        ),
      );
      if (selectedId == '__new__') {
        final name = await _requestPlaylistName();
        if (name == null || name.isEmpty) return;
        await create(name);
        playlists = await store.load(ownerId);
        selectedId = playlists.isEmpty ? null : playlists.first.id;
      }
    }

    if (selectedId == null) return;
    final remotePlaylist = RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(selectedId);
    if (auth is AuthSignedIn && remotePlaylist) {
      try {
        await ref.read(authSessionProvider.notifier).api.addPlaylistTrack(selectedId, track.id);
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not sync this song to your playlist.')));
        return;
      }
    }
    await store.addTrack(ownerId, selectedId, FavoriteTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      artworkUrl: track.artworkUrl,
      durationMs: track.duration.inMilliseconds,
    ));
    if (!mounted) return;
    ref.read(playlistRefreshSignalProvider.notifier).state++;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to playlist')));
  }

  Future<void> _addFavorite(BzTrack track) async {
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    final favorites = ref.read(favoritesStoreProvider);
    if (!await favorites.isFavorite(track.id, ownerId: ownerId)) {
      await favorites.toggle(
        FavoriteTrack(
          id: track.id,
          title: track.title,
          artist: track.artist,
          artworkUrl: track.artworkUrl,
          durationMs: track.duration.inMilliseconds,
        ),
        ownerId: ownerId,
      );
      await ref.read(outboxSyncProvider).drainIfSignedIn();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Library updated')),
    );
  }

  void _download(BzTrack track) {
    // Metadata providers do not grant offline-download rights.
    if (track.id.startsWith('bz:') || track.id.startsWith('bzv:')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offline downloads are not available for this catalogue source.')),
      );
      return;
    }
    ref.read(downloadProgressProvider.notifier).download(track);
  }

  void _openTrack(BzTrack track) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrackDetailScreen(
        track: TrackInfo(
          id: track.id,
          title: track.title,
          artist: track.artist,
          artworkUrl: track.artworkUrl,
          duration: track.duration,
        ),
        relatedTracks: [
          for (final item in _results)
            TrackInfo(
              id: item.id,
              title: item.title,
              artist: item.artist,
              artworkUrl: item.artworkUrl,
              duration: item.duration,
            ),
        ],
        origin: _searchLibrary ? 'library' : 'search',
      ),
    ));
  }

  Future<void> _watchMusicVideo(BzTrack track) async {
    final generation = _searchGeneration;
    try {
      final id = track.id.substring('bz:youtube_music:'.length);
      final result = await ref.read(authSessionProvider.notifier).api.musicVideoForSong(id);
      if (!mounted || generation != _searchGeneration) return;
      final video = result['videoId'];
      if (video is String) {
        await openYouTubePlayer(context: context, ref: ref, videoId: video,
            title: track.title, artist: track.artist, artworkUrl: track.artworkUrl);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No official music video for this recording.')),
        );
      }
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load the music video. Try again.')),
      );
    }
  }

  Future<void> _play(BzTrack track) async {
    final embeddedId = track.id.startsWith('bzv:')
        ? track.id.substring(4)
        : null;
    if (embeddedId != null) {
      // A video is watched in the official visible iframe, never extracted
      // into Breezze's native audio-only playback queue.
      await openYouTubePlayer(
        context: context,
        ref: ref,
        videoId: embeddedId,
        title: track.title,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
      );
      return;
    }
    if (isMetadataOnlyTrackId(track.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This result is catalogue metadata only. Native playback is not available from this source.')),
        );
      }
      return;
    }

    final playableTracks = _results
        .where((item) => !isMetadataOnlyTrackId(item.id))
        .toList();
    final queue = [
      for (final item in playableTracks)
        TrackInfo(
          id: item.id,
          title: item.title,
          artist: item.artist,
          artworkUrl: item.artworkUrl,
          duration: item.duration,
        )
    ];
    final index = playableTracks.indexOf(track);
    if (queue.isEmpty || index < 0) return;
    ref.read(playerControllerProvider.notifier).playTrack(
          trackId: track.id,
          queue: queue,
          startIndex: index.clamp(0, queue.length - 1),
          origin: 'search',
          sourceContext: 'Search',
        );
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      final previousOwner = previous is AuthSignedIn ? previous.userId : 'guest';
      final nextOwner = next is AuthSignedIn ? next.userId : 'guest';
      if (previousOwner != nextOwner) {
        _typeaheadTimer?.cancel();
        _searchGeneration++;
        setState(() {
          _recentSearches = [];
          _results = [];
          _loading = false;
          _searched = false;
          _error = null;
        });
        _loadHistory();
      }
    });
    final theme = Theme.of(context);
    final progress = ref.watch(downloadProgressProvider);

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Search', style: theme.textTheme.displayMedium),
                const SizedBox(height: 16),
                // PRT-01 search pill: --radius-pill (capsule) with the
                // surface-hover fill and a leading magnifier — the Apple
                // Music search field treatment.
                TextField(
                  controller: _controller,
                  onSubmitted: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: _searchVideos && !_searchLibrary
                        ? 'Search official music videos'
                        : 'Songs, artists and more',
                    prefixIcon: BzSvgIcon(name: 'search', color: theme.bzText2),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: BzSvgIcon(name: 'close', color: theme.bzText2),
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                            },
                          ),
                    filled: true,
                    fillColor: theme.bzSurface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(BzRadius.capsule),
                      borderSide: BorderSide(color: theme.bzSeparator),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(BzRadius.capsule),
                      borderSide: BorderSide(color: theme.bzSeparator),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(BzRadius.capsule),
                      borderSide: BorderSide(color: theme.bzAccent),
                    ),
                  ),
                  onChanged: _onQueryChanged,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _SearchScopePill(
                      label: 'Breezze',
                      active: !_searchLibrary,
                      onTap: () {
                        setState(() => _searchLibrary = false);
                        if (_controller.text.trim().isNotEmpty) {
                          _search(_controller.text);
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _SearchScopePill(
                      label: 'Your Library',
                      active: _searchLibrary,
                      onTap: () {
                        setState(() => _searchLibrary = true);
                        if (_controller.text.trim().isNotEmpty) {
                          _search(_controller.text);
                        }
                      },
                    ),
                  ],
                ),
                if (!_searchLibrary) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _SearchScopePill(
                        label: 'Songs',
                        active: !_searchVideos,
                        onTap: () {
                          if (_searchVideos) {
                            setState(() => _searchVideos = false);
                            if (_controller.text.trim().isNotEmpty) {
                              _search(_controller.text);
                            }
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      _SearchScopePill(
                        label: 'Music Videos',
                        active: _searchVideos,
                        onTap: () {
                          if (!_searchVideos) {
                            setState(() => _searchVideos = true);
                            if (_controller.text.trim().isNotEmpty) {
                              _search(_controller.text);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: 7,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (_, __) => const BzSkeletonTrackRow(),
                  )
                : !_searched
                    ? _buildRecentSearches(theme)
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          )
                        : _results.isEmpty
                            ? Center(
                                child: Text(
                                  (_searchVideos && !_searchLibrary
                                      ? 'No official videos found for "${_controller.text.trim()}"'
                                      : 'No results for "${_controller.text.trim()}"'),
                                  style: theme.textTheme.titleMedium,
                                ),
                              )
                            : ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(0, 8, 0, 220),
                                itemCount: _results.length,
                                itemBuilder: (context, index) {
                                  final track = _results[index];
                                  final value = progress[track.id];
                                  return ListTile(
                                    leading: track.artworkUrl != null
                                        ? ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(
                                                    BzRadius.artwork),
                                            child: Image.network(
                                              track.artworkUrl!,
                                              width: 48,
                                              height: 48,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  BzBnoteMark(
                                                size: 48,
                                                color: theme.bzText2,
                                              ),
                                            ),
                                          )
                                        : BzBnoteMark(
                                            size: 48, color: theme.bzText2),
                                    title: Text(
                                      track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: value != null
                                        ? ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(2),
                                            child: LinearProgressIndicator(
                                              value: value,
                                              minHeight: 3,
                                              backgroundColor:
                                                  theme.bzSeparator,
                                              color: theme.bzAccent,
                                            ),
                                          )
                                        : Text(
                                            track.id.startsWith('bz:deezer:')
                                                ? '${track.artist} · ${track.hasPreview ? 'Deezer · preview available' : 'Deezer catalog'}'
                                                : track.id.startsWith('bz:youtube_music:')
                                                        ? '${track.artist} · YouTube Music'
                                                        : track.id.startsWith('bz:jamendo:')
                                                            ? '${track.artist} · Jamendo'
                                                            : track.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    // On compact phones one action menu
                                    // replaces three cramped trailing icons.
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (track.id.startsWith('bzv:') ||
                                            track.hasPreview || canQueueTrackId(track.id))
                                          IconButton(
                                            tooltip: track.id.startsWith('bzv:')
                                                ? 'Watch music video'
                                                : 'Play',
                                            icon: const BzSvgIcon(name: 'play', size: 20),
                                            onPressed: () => _play(track),
                                          ),
                                        if (!track.id.startsWith('bzv:'))
                                          PopupMenuButton<String>(
                                            tooltip: 'Song actions',
                                            icon: const BzSvgIcon(name: 'more-vertical', size: 20),
                                            onSelected: (action) {
                                              if (action == 'original') {
                                                openYouTubePlayer(
                                                  context: context,
                                                  ref: ref,
                                                  videoId: track.id.substring('bz:youtube_music:'.length),
                                                  title: track.title,
                                                  artist: track.artist,
                                                  artworkUrl: track.artworkUrl,
                                                );
                                              } else if (action == 'video') {
                                                _watchMusicVideo(track);
                                              } else if (action == 'playlist') {
                                                _showAddToPlaylist(track);
                                              } else if (action == 'favorite') {
                                                _addFavorite(track);
                                              } else if (action == 'download') {
                                                _download(track);
                                              } else if (action == 'play_next' ||
                                                  action == 'play_last') {
                                                final item = TrackInfo(
                                                  id: track.id,
                                                  title: track.title,
                                                  artist: track.artist,
                                                  artworkUrl: track.artworkUrl,
                                                  duration: track.duration,
                                                );
                                                final controller = ref.read(playerControllerProvider.notifier);
                                                if (action == 'play_next') {
                                                  controller.playNext(item,
                                                      origin: 'search',
                                                      sourceContext: 'Search');
                                                } else {
                                                  controller.playLast(item,
                                                      origin: 'search',
                                                      sourceContext: 'Search');
                                                }
                                              }
                                            },
                                            itemBuilder: (context) => [
                                              if (isYouTubeSongId(track.id)) ...[
                                                const PopupMenuItem(value: 'original', child: Text('Open YouTube player')),
                                                const PopupMenuItem(value: 'video', child: Text('Watch music video')),
                                              ],
                                              const PopupMenuItem(
                                                value: 'playlist',
                                                child: Text('Add to Playlist'),
                                              ),
                                              const PopupMenuItem(
                                                value: 'favorite',
                                                child: Text('Add to Library'),
                                              ),
                                              if (canQueueTrackId(track.id)) ...[
                                                const PopupMenuItem(
                                                  value: 'play_next',
                                                  child: Text('Play Next'),
                                                ),
                                                const PopupMenuItem(
                                                  value: 'play_last',
                                                  child: Text('Add to Queue'),
                                                ),
                                              ],
                                              if (canRequestOfflineDownload(track.id))
                                                const PopupMenuItem(
                                                  value: 'download',
                                                  child: Text('Download'),
                                                ),
                                            ],
                                          ),
                                        if (value != null)
                                          const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          ),
                                      ],
                                    ),
                                    onTap: () => track.id.startsWith('bzv:') ||
                                            (canQueueTrackId(track.id) || track.hasPreview)
                                        ? _play(track)
                                        : _openTrack(track),
                                  );
                                },
                              ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentSearches(ThemeData theme) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, BzBreakpoints.bottomClearance(context, compact: 180)),
      children: [
        if (_searchVideos && supportsDeviceVideo)
          ListTile(
            leading: const BzSvgIcon(name: 'video'),
            title: const Text('Open a music video'),
            onTap: () => pickDeviceVideo(context),
          ),
        ListTile(
          leading: const BzSvgIcon(name: 'play'),
          title: const Text('Open audio files'),
          onTap: () => pickDeviceAudio(context, ref),
        ),
        if (_recentSearches.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text('Recent Searches',
                    style: theme.textTheme.titleLarge),
              ),
              TextButton(
                onPressed: _clearHistory,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final query in _recentSearches)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: BzSvgIcon(name: 'history', color: theme.bzText2),
              title: Text(query,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _reuseSearch(query),
              trailing: IconButton(
                tooltip: 'Remove search',
                icon: BzSvgIcon(name: 'close', color: theme.bzText2),
                onPressed: () => _removeHistory(query),
              ),
            ),
          const SizedBox(height: 20),
        ],
        Text('Suggested searches', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.35,
          children: [
            for (final item in _suggestedSearches.entries)
              Material(
                color: theme.bzSurface1,
                borderRadius: BorderRadius.circular(BzRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(BzRadius.card),
                  onTap: () => _reuseSearch(item.value),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(BzRadius.card),
                      border: Border.all(color: theme.bzSeparator),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      item.key,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Search scope pill — capsule (spec --radius-pill) with a solid text1
/// fill when active, surface2 when not. Mirrors the Library section pill.
class _SearchScopePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SearchScopePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: BzMotion.fastMs),
          curve: const Cubic(0.22, 1, 0.36, 1),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? theme.bzText1 : theme.bzSurface2,
            borderRadius: BorderRadius.circular(BzRadius.capsule),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: BzType.subheadline,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? theme.bzBackground : theme.bzText2,
            ),
          ),
        ),
      ),
    );
  }
}
