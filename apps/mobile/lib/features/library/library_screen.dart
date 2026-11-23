import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/audio/playback_source_policy.dart';
import '../../app/playlist_store.dart';
import '../../app/saved_album_store.dart';
import '../../app/library_section_preferences_store.dart';
import '../../core/auth/auth_session.dart';
import '../../core/database/outbox_sync_service.dart';
import '../../widgets/bz_brand_icons.dart';
import '../downloads/downloads_screen.dart';
import 'playlist_detail_screen.dart';
import '../catalog/catalog_detail_screens.dart';
import '../player/player_controller.dart';

/// Library navigation follows the user's requested section order. Only
/// Songs/Favorites and Downloaded currently have live local data; the other
/// collection types remain honest empty states until their APIs are connected.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _allSections = [
    'Playlists',
    'Artists',
    'Albums',
    'Songs',
    'Genres',
    'Compilations',
  ];

  Set<String> _visibleSections = {'Playlists', 'Artists', 'Albums', 'Songs'};
  String _selected = 'Playlists';
  String? _activeGenre;
  final _playlistStore = PlaylistStore();
  String _ownerId = 'guest';
  List<UserPlaylist> _playlists = [];
  List<FavoriteTrack> _favorites = [];
  List<SavedAlbum> _albums = [];
  var _loading = true;
  bool _storageUnavailable = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final generation = ++_loadGeneration;
    final auth = ref.read(authSessionProvider);
    final ownerId = auth is AuthSignedIn ? auth.userId : 'guest';
    var storageUnavailable = false;
    List<FavoriteTrack> favorites;
    try {
      favorites = await ref.read(favoritesStoreProvider).load(ownerId: ownerId);
    } catch (_) {
      favorites = <FavoriteTrack>[];
      storageUnavailable = true;
    }
    List<UserPlaylist> playlists;
    try {
      playlists = await _playlistStore.load(ownerId);
    } catch (_) {
      playlists = <UserPlaylist>[];
      storageUnavailable = true;
    }
    final albumStore = SavedAlbumStore();
    List<SavedAlbum> savedAlbums;
    try {
      savedAlbums = await albumStore.load(ownerId);
    } catch (_) {
      savedAlbums = <SavedAlbum>[];
      storageUnavailable = true;
    }
    Set<String> visibleSections;
    try {
      visibleSections = await LibrarySectionPreferencesStore().load(ownerId);
    } catch (_) {
      visibleSections = <String>{'Playlists', 'Artists', 'Albums', 'Songs'};
      storageUnavailable = true;
    }
    // A corrupted or obsolete preference set must not make firstWhere throw.
    visibleSections = visibleSections.intersection(_allSections.toSet());
    if (visibleSections.isEmpty) {
      visibleSections = <String>{'Playlists', 'Artists', 'Albums', 'Songs'};
    }
    if (!mounted || generation != _loadGeneration) return;
    if (auth is AuthSignedIn) {
      try {
        await albumStore.syncWithCloud(
          ownerId,
          ref.read(authSessionProvider.notifier).api,
          ownerStillActive: () {
            if (!mounted) return false;
            final active = ref.read(authSessionProvider);
            return active is AuthSignedIn && active.userId == ownerId;
          },
        );
        savedAlbums = await albumStore.load(ownerId);
      } catch (_) {
        // Keep owner-specific cached albums and pending operations offline.
      }
      try {
        final remote = await ref.read(authSessionProvider.notifier).api.playlists();
        await _playlistStore.mergeRemote(ownerId, remote);
        playlists = await _playlistStore.load(ownerId);
      } catch (_) {
        // Local cache remains usable while offline; cloud changes sync next refresh.
      }
    }
    final currentAuth = ref.read(authSessionProvider);
    final currentOwnerId =
        currentAuth is AuthSignedIn ? currentAuth.userId : 'guest';
    if (!mounted || generation != _loadGeneration || currentOwnerId != ownerId) return;
    setState(() {
      _ownerId = ownerId;
      _favorites = favorites;
      _playlists = playlists;
      _albums = savedAlbums;
      _visibleSections = visibleSections;
      if (_selected != 'Downloaded' && !_visibleSections.contains(_selected)) {
        _selected = _allSections.firstWhere(_visibleSections.contains);
      }
      _storageUnavailable = storageUnavailable;
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
    String? remoteId;
    if (auth is AuthSignedIn) {
      try {
        final remote = await ref.read(authSessionProvider.notifier).api.createPlaylist(name.trim());
        remoteId = remote['id'] as String?;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Playlist saved locally; account sync is unavailable.')),
          );
        }
      }
    }
    await _playlistStore.create(_ownerId, name, id: remoteId);
    if (!mounted) return;
    setState(() => _selected = 'Playlists');
    await _refresh();
  }

  void _openPlaylist(UserPlaylist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailScreen(
          ownerId: _ownerId,
          playlistId: playlist.id,
          onChanged: _refresh,
        ),
      ),
    );
  }

  List<TrackInfo> _queue() => [
        for (final f in _favorites)
          if (canQueueTrackId(f.id)) f.toTrackInfo(),
      ];

  Future<void> _playAll() async {
    if (_favorites.isEmpty) return;
    final nativeIndex = _favorites.indexWhere((item) => canQueueTrackId(item.id));
    if (nativeIndex >= 0) {
      if (_favorites.any((item) => !canQueueTrackId(item.id)) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Catalogue-only tracks are excluded from native playback; only playable tracks enter the queue.')),
        );
      }
      await _playOne(nativeIndex);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved songs have an authorized playback source yet.')),
      );
    }
  }

  Future<void> _playOne(int index) async {
    final track = _favorites[index];
    if (!canQueueTrackId(track.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This saved item has metadata only; Breezze cannot play it from this source.')),
        );
      }
      return;
    }
    final queue = _queue();
    final queueIndex = queue.indexWhere((item) => item.id == track.id);
    if (queueIndex < 0) return;
    await ref.read(playerControllerProvider.notifier).playTrack(
          trackId: track.id,
          queue: queue,
          startIndex: queueIndex,
          origin: 'library',
          sourceContext: 'Songs',
        );
  }

  Future<void> _editSections() async {
    final draft = Set<String>.from(_visibleSections);
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Customize Library',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('Choose which sections appear in your Library.',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
                for (final section in _allSections)
                  CheckboxListTile(
                    value: draft.contains(section),
                    title: Text(section),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (value) => setSheetState(() {
                      if (value == true) {
                        draft.add(section);
                      } else {
                        if (draft.length > 1) draft.remove(section);
                      }
                    }),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(draft),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    try {
      await LibrarySectionPreferencesStore().save(_ownerId, result);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save Library section preferences.')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _visibleSections = result;
      if (_selected != 'Downloaded' && !_visibleSections.contains(_selected)) {
        _selected = _visibleSections.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authSessionProvider, (previous, next) {
      final oldOwner = previous is AuthSignedIn ? previous.userId : 'guest';
      final newOwner = next is AuthSignedIn ? next.userId : 'guest';
      if (oldOwner != newOwner) {
        // Clear in-memory account data synchronously to prevent other
        // listeners from briefly seeing the previous owner's library.
        setState(() {
          _ownerId = newOwner;
          _playlists = [];
          _favorites = [];
          _albums = [];
          _selected = 'Playlists';
          _visibleSections = {'Playlists', 'Artists', 'Albums', 'Songs'};
          _storageUnavailable = false;
          _loading = true;
        });
      }
      _refresh();
    });
    ref.listen<int>(playlistRefreshSignalProvider, (previous, next) => _refresh());
    ref.listen<int>(savedAlbumRefreshProvider, (previous, next) => _refresh());
    final theme = Theme.of(context);
    final sections = [..._allSections.where(_visibleSections.contains), 'Downloaded'];

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text('Library', style: theme.textTheme.displayMedium),
                ),
                if (_selected == 'Playlists')
                  IconButton(
                    tooltip: 'Create playlist',
                    onPressed: _createPlaylist,
                    icon: BzSvgIcon(name: 'plus', color: theme.bzAccent),
                  ),
                TextButton(
                  onPressed: _editSections,
                  child: const Text('Edit'),
                ),
              ],
            ),
          ),
          if (!_loading && _storageUnavailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Some saved music could not be loaded.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.bzText2),
                      ),
                    ),
                    TextButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          // Capsule pill section selector — spec §2.3 tab indicators use
          // --radius-pill. Solid active fill, no outline chips: the Apple
          // Music Library filter treatment (quiet chrome, artwork forward).
          SizedBox(
            height: 52,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: sections.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final section = sections[index];
                final active = section == _selected;
                return BzFilterPill(
                  label: section,
                  active: active,
                  onTap: () => setState(() {
                    if (_selected != section) _activeGenre = null;
                    _selected = section;
                  }),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _selected == 'Downloaded'
                ? const DownloadsScreen()
                : _selected == 'Songs'
                    ? _buildSongs(theme)
                    : _selected == 'Playlists'
                        ? _buildPlaylists(theme)
                        : _selected == 'Albums'
                            ? _buildAlbums(theme)
                        : _selected == 'Artists'
                            ? _buildArtists(theme)
                        : _selected == 'Genres'
                            ? _buildGenres(theme)
                        : _selected == 'Compilations'
                            ? _buildAlbums(
                                theme,
                                selectedAlbums: SavedAlbumGroups.compilations(_albums),
                                emptyTitle: 'No saved compilations',
                                emptyDetail: 'Save an album identified as a compilation by its catalog to see it here.',
                              )
                            : _buildEmptySection(theme, _selected),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylists(ThemeData theme) {
    if (_loading) return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, __) => const BzSkeletonTrackRow(),
    );
    if (_playlists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BzBnoteMark(size: 58, color: theme.bzText2),
              const SizedBox(height: 16),
              Text('Create your first playlist',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Build collections of songs and keep them on this device.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.bzText2),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _createPlaylist,
                icon: BzSvgIcon(
                  name: 'plus',
                  color: theme.bzBackground,
                  size: 18,
                ),
                label: const Text('New Playlist'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(8, 4, 8, BzBreakpoints.bottomClearance(context, compact: 150)),
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        final artwork = playlist.tracks
            .where((track) => track.artworkUrl != null)
            .map((track) => track.artworkUrl!)
            .toList();
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(BzRadius.artwork),
            child: artwork.isEmpty
                ? Container(
                    width: 54,
                    height: 54,
                    color: theme.bzSurface1,
                    alignment: Alignment.center,
                    child: BzBnoteMark(size: 28, color: theme.bzText2),
                  )
                : Image.network(
                    artwork.first,
                    width: 54,
                    height: 54,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        BzBnoteMark(size: 54, color: theme.bzText2),
                  ),
          ),
          title: Text(playlist.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${playlist.tracks.length} songs · On this device',
            style: TextStyle(color: theme.bzText2),
          ),
          trailing: BzSvgIcon(name: 'chevron-right', color: theme.bzText2),
          onTap: () => _openPlaylist(playlist),
        );
      },
    );
  }

  Widget _buildAlbums(
    ThemeData theme, {
    List<SavedAlbum>? selectedAlbums,
    String emptyTitle = 'No saved albums',
    String emptyDetail = 'Open an album in New or an artist page, then choose Add to Library.',
  }) {
    final albums = selectedAlbums ?? _albums;
    if (_loading) {
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (_, __) => const BzSkeletonTrackRow(),
      );
    }
    if (albums.isEmpty) {
      return _emptyState(theme, emptyTitle, emptyDetail);
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        8, 4, 8, BzBreakpoints.bottomClearance(context, compact: 150),
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(BzRadius.artwork),
            child: album.artworkUrl == null
                ? Container(
                    width: 54, height: 54, color: theme.bzSurface2,
                    alignment: Alignment.center,
                    child: BzBnoteMark(size: 28, color: theme.bzText2),
                  )
                : Image.network(
                    album.artworkUrl!, width: 54, height: 54,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        BzBnoteMark(size: 54, color: theme.bzText2),
                  ),
          ),
          title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AppleAlbumCatalogScreen(
              albumId: album.id,
              title: album.title,
              artist: album.artist,
              artworkUrl: album.artworkUrl,
              appleUrl: album.catalogUrl,
            ),
          )),
          trailing: IconButton(
            tooltip: 'Remove saved album',
            icon: const BzSvgIcon(name: 'more-vertical'),
            onPressed: () async {
              final shouldRemove = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Remove album?'),
                  content: Text('Remove "${album.title}" from your library?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              );
              if (shouldRemove != true || !mounted) return;
              try {
                final store = SavedAlbumStore();
                final owner = _ownerId;
                await store.remove(owner, album.id);
                final auth = ref.read(authSessionProvider);
                if (auth is AuthSignedIn && auth.userId == owner) {
                  try {
                    await store.syncWithCloud(
                      owner,
                      ref.read(authSessionProvider.notifier).api,
                      ownerStillActive: () {
                        if (!mounted) return false;
                        final active = ref.read(authSessionProvider);
                        return active is AuthSignedIn && active.userId == owner;
                      },
                    );
                  } catch (_) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text(
                          'Removed from this device. Cloud sync will retry when connected.',
                        )),
                      );
                    }
                  }
                }
                if (!mounted) return;
                ref.invalidate(isAlbumSavedProvider(
                  (ownerId: _ownerId, albumId: album.id),
                ));
                ref.read(savedAlbumRefreshProvider.notifier).state++;
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not remove saved album.')),
                  );
                }
              }
            },
          ),
        );
      },
    );
  }

  Widget _buildGenres(ThemeData theme) {
    if (_loading) {
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (_, __) => const BzSkeletonTrackRow(),
      );
    }
    final selectedGenre = _activeGenre;
    if (selectedGenre != null) {
      return Column(
        children: [
          ListTile(
            leading: BzSvgIcon(name: 'chevron-left', color: theme.bzText1),
            title: Text(selectedGenre, style: theme.textTheme.titleLarge),
            subtitle: const Text('Saved albums'),
            onTap: () => setState(() => _activeGenre = null),
          ),
          Expanded(
            child: _buildAlbums(
              theme,
              selectedAlbums: SavedAlbumGroups.forGenre(_albums, selectedGenre),
              emptyTitle: 'No albums in this genre',
              emptyDetail: 'Album categories are based on actual catalog metadata.',
            ),
          ),
        ],
      );
    }
    final genres = SavedAlbumGroups.genres(_albums);
    if (genres.isEmpty) {
      return _emptyState(
        theme,
        'No categorized albums',
        'Save albums with verified genre metadata to browse them by genre.',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        8, 4, 8, BzBreakpoints.bottomClearance(context, compact: 150),
      ),
      itemCount: genres.length,
      itemBuilder: (context, index) {
        final genre = genres[index];
        final albums = SavedAlbumGroups.forGenre(_albums, genre);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          leading: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: theme.bzSurface2,
              borderRadius: BorderRadius.circular(BzRadius.card),
            ),
            alignment: Alignment.center,
            child: BzSvgIcon(name: 'music-note', color: theme.bzText1),
          ),
          title: Text(genre),
          subtitle: Text('${albums.length} saved ${albums.length == 1 ? 'album' : 'albums'}'),
          trailing: BzSvgIcon(name: 'chevron-right', color: theme.bzText2),
          onTap: () => setState(() => _activeGenre = genre),
        );
      },
    );
  }

  Widget _buildArtists(ThemeData theme) {
    if (_loading) return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, __) => const BzSkeletonTrackRow(),
    );
    final grouped = <String, List<FavoriteTrack>>{};
    for (final track in _favorites) {
      grouped.putIfAbsent(track.artist.trim().isEmpty ? 'Unknown artist' : track.artist, () => []).add(track);
    }
    if (grouped.isEmpty) return _emptyState(theme, 'No artists yet', 'Save songs to build your artist library.');
    final artists = grouped.entries.toList()..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 150),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final entry = artists[index];
        return ListTile(
          leading: CircleAvatar(backgroundColor: theme.bzSurface2, child: BzSvgIcon(name: 'mic', color: theme.bzText1)),
          title: Text(entry.key),
          subtitle: Text('${entry.value.length} saved songs'),
          trailing: BzSvgIcon(name: 'chevron-right', color: theme.bzText2),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtistDetailScreen(
                artist: entry.key,
                savedTracks: entry.value,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongs(ThemeData theme) {
    if (_loading) return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, __) => const BzSkeletonTrackRow(),
    );
    if (_favorites.isEmpty) {
      return _emptyState(
        theme,
        'No saved songs yet',
        'Star a track while listening and it will appear here.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_favorites.length} saved songs',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: _playAll,
                icon: SvgPicture.asset(
                  'assets/icons/play.svg',
                  width: 15,
                  height: 15,
                  colorFilter: ColorFilter.mode(
                    theme.bzAccent,
                    BlendMode.srcIn,
                  ),
                ),
                label: const Text('Play all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(8, 0, 8, BzBreakpoints.bottomClearance(context, compact: 150)),
            itemCount: _favorites.length,
            itemBuilder: (context, i) {
              final fav = _favorites[i];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(BzRadius.artwork),
                  child: fav.artworkUrl != null
                      ? Image.network(
                          fav.artworkUrl!,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              BzBnoteMark(size: 50, color: theme.bzText2),
                        )
                      : BzBnoteMark(size: 50, color: theme.bzText2),
                ),
                title: Text(fav.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(fav.artist,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _playOne(i),
                trailing: IconButton(
                  tooltip: 'Remove from favorites',
                  icon: SvgPicture.asset(
                    'assets/icons/star-filled.svg',
                    width: 20,
                    height: 20,
                    colorFilter: ColorFilter.mode(
                      theme.bzWarning,
                      BlendMode.srcIn,
                    ),
                  ),
                  onPressed: () async {
                    await ref.read(favoritesStoreProvider).toggle(fav, ownerId: _ownerId);
                    await ref.read(outboxSyncProvider).drainIfSignedIn();
                    _refresh();
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmptySection(ThemeData theme, String section) {
    if (_loading) {
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (_, __) => const BzSkeletonTrackRow(),
      );
    }
    final detail = switch (section) {
      'Playlists' => 'Your created and saved playlists will appear here.',
      'Artists' => 'Artists you follow or save will appear here.',
      'Albums' => 'Albums added to your library will appear here.',
      'Genres' => 'Genres represented in your saved music will appear here.',
      'Compilations' => 'Compilation albums in your library will appear here.',
      _ => 'Your music collection will appear here.',
    };
    return _emptyState(theme, 'No $section yet', detail);
  }

  Widget _emptyState(ThemeData theme, String title, String detail) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BzBnoteMark(size: 58, color: theme.bzText2),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.bzText2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Library section pill — capsule (spec --radius-pill) with a solid
/// text1 fill when active, surface2 when not. 36pt visual height with
/// a generous hit area for the 44pt minimum.
