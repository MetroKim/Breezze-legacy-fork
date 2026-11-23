import 'package:breezze_api_client/breezze_api_client.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/bootstrap.dart';
import '../../core/audio/playback_source_policy.dart';
import '../video/official_music_video_screen.dart';
import '../catalog/catalog_detail_screens.dart';
import '../../core/auth/auth_session.dart';
import '../../core/database/outbox_sync_service.dart';
import '../../app/downloads_controller.dart';
import '../../features/player/player_controller.dart';
import '../../widgets/bz_brand_icons.dart';

/// Browse uses live source search for genre discovery. It does not label
/// provider search results as official charts or editorial recommendations.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  static const _genres = [
    'Afrobeats',
    'Bongo Flava',
    'Amapiano',
    'Gospel',
    'Hip-Hop',
    'R&B',
    'Jazz',
    'Electronic',
  ];

  String _selectedGenre = _genres.first;
  List<BzTrack> _tracks = [];
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadGenre(_selectedGenre);
    });
  }

  Future<void> _loadGenre(String genre) async {
    final requestId = ++_requestId;
    setState(() {
      _selectedGenre = genre;
      _loading = true;
      _error = null;
      _tracks = [];
    });

    try {
      final result = await ref.read(catalogSourceProvider).search('$genre music');
      if (!mounted || requestId != _requestId) return;

      if (result is ProviderOk<List<ProviderTrack>>) {
        setState(() {
          _tracks = result.value
              .map((track) => BzTrack(
                    id: track.breezzeTrackId,
                    title: track.title,
                    artist: track.artist,
                    artworkUrl: track.artworkUrl,
                    duration: track.duration,
                  ))
              .toList();
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _error = 'This music source could not return results right now.';
        });
      }
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = 'Could not connect to the music source. Try again.';
      });
    }
  }

  void _openCollection(_BrowseDestination destination) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _BrowseCollectionScreen(destination: destination),
      ),
    );
  }

  Future<void> _play(int index) async {
    if (_tracks.isEmpty) return;
    final selected = _tracks[index];
    if (!canQueueTrackId(selected.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This result is catalogue metadata only. Native playback is not available from this source.')),
        );
      }
      return;
    }
    final playableTracks = _tracks
        .where((track) => canQueueTrackId(track.id))
        .toList();
    final queue = [
      for (final track in playableTracks)
        TrackInfo(
          id: track.id,
          title: track.title,
          artist: track.artist,
          artworkUrl: track.artworkUrl,
          duration: track.duration,
        ),
    ];
    final queueIndex = playableTracks.indexWhere((track) => track.id == selected.id);
    if (queueIndex < 0) return;
    await ref.read(playerControllerProvider.notifier).playTrack(
          trackId: selected.id,
          queue: queue,
          startIndex: queueIndex,
          origin: 'browse',
          sourceContext: _selectedGenre,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ref.watch(downloadProgressProvider);
    return SafeArea(
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New', style: theme.textTheme.displayMedium),
                  const SizedBox(height: 6),
                  Text('New releases, music videos, charts, genres and more.', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 18),
                  Text('Explore by genre', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  // Capsule pill genre rail — spec §2.3 tab indicators use
                  // --radius-pill. Same treatment as Library and Search.
                  SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _genres.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final genre = _genres[index];
                        final selected = genre == _selectedGenre;
                        return BzFilterPill(
                          label: genre,
                          active: selected,
                          onTap: () => _loadGenre(genre),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text('Discover', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final columns = width >= 1080 ? 4 : width >= 620 ? 3 : 2;
                return SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final destination = _browseDestinations[index];
                      return Material(
                        color: theme.bzSurface1,
                        borderRadius: BorderRadius.circular(BzRadius.card),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(BzRadius.card),
                          onTap: () => _openCollection(destination),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(BzRadius.card),
                              border: Border.all(color: theme.bzSeparator),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: theme.bzSurface2,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  alignment: Alignment.center,
                                  child: BzSvgIcon(name: destination.icon, size: 19, color: theme.bzAccent),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(destination.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
                                      const SizedBox(height: 3),
                                      Text(destination.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2, fontSize: 10)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: _browseDestinations.length,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: width < 380 ? 2.0 : 2.35,
                  ),
                );
              },
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(child: Text(_selectedGenre + ' discovery', style: theme.textTheme.titleLarge)),
                  if (!_loading && _tracks.isNotEmpty)
                    Text(_tracks.length.toString() + ' matches', style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2)),
                ],
              ),
            ),
          ),
          if (_loading)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, __) => const Padding(padding: EdgeInsets.only(bottom: 14), child: BzSkeletonTrackRow()),
                  childCount: 6,
                ),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessageState(icon: 'wifi-off', title: 'Music is unavailable', message: _error!, onRetry: () => _loadGenre(_selectedGenre)),
            )
          else if (_tracks.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessageState(icon: 'music-note', title: 'No tracks found', message: 'Try another genre or search for an artist.', onRetry: () => _loadGenre(_selectedGenre)),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(0, 0, 0, BzBreakpoints.bottomClearance(context, compact: 220)),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final track = _tracks[index];
                    final download = progress[track.id];
                    return ListTile(
                      leading: track.artworkUrl == null
                          ? BzBnoteMark(size: 48, color: theme.bzText2)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(BzRadius.artwork),
                              child: Image.network(track.artworkUrl!, width: 48, height: 48, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => BzBnoteMark(size: 48, color: theme.bzText2)),
                            ),
                      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: download != null
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                              tooltip: 'Download',
                              icon: const BzSvgIcon(name: 'download', size: 20),
                              onPressed: !canRequestOfflineDownload(track.id)
                                  ? null
                                  : () => ref.read(downloadProgressProvider.notifier).download(track),
                            ),
                      onTap: () => _play(index),
                    );
                  },
                  childCount: _tracks.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  final String icon;
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BzSvgIcon(name: icon, size: 36, color: theme.bzText2),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _BrowseDestination {
  final String title;
  final String description;
  final String icon;

  const _BrowseDestination(this.title, this.description, this.icon);

  String get availabilityMessage {
    switch (title) {
      case 'Latest Songs':
        return 'A verified catalog feed with addition timestamps and territory data is not connected.';
      case 'New Releases':
        return 'Verified album and single records with confirmed release dates are required.';
      case 'Trending Songs':
      case 'Daily Top 100':
      case 'Charts':
        return 'Rankings require a named chart source, territory, reporting window and update timestamp. Search results cannot be used as rankings.';
      case 'Coming Soon':
        return 'Upcoming release announcements need verified artist, release-date and territory metadata.';
      case 'Music Videos':
        return 'An authorized video catalog and playback permissions are not connected.';
      case 'City Charts':
        return 'City-level rankings require a verified local chart provider and a documented methodology.';
      case 'Upcoming Concerts':
        return 'A verified event feed must supply artist, venue, date, location and ticket-source details.';
      case 'Seasonal Collections':
        return 'Seasonal collections require a maintained editorial feed and licensed track references.';
      case 'Artist Spotlight':
        return 'Artist spotlights require editorial selection and canonical artist records.';
      default:
        return 'A verified catalog provider is required for this section.';
    }
  }

  List<String> get previewSections {
    switch (title) {
      case 'Latest Songs':
        return ['Recently added tracks', 'Verified addition dates', 'Catalog source'];
      case 'New Releases':
        return ['Albums and EPs', 'Singles', 'Release calendar'];
      case 'Trending Songs':
        return ['Fast risers', 'Most played', 'Territory and reporting window'];
      case 'Daily Top 100':
        return ['Rank and movement', 'Track and artist', 'Chart date and territory'];
      case 'Coming Soon':
        return ['Upcoming albums', 'Upcoming singles', 'Confirmed release dates'];
      case 'Music Videos':
        return ['Official videos', 'Video details', 'Authorized playback'];
      case 'Charts':
        return ['Global charts', 'Regional charts', 'Genre charts'];
      case 'City Charts':
        return ['City rankings', 'Local reporting window', 'Source attribution'];
      case 'Upcoming Concerts':
        return ['Nearby events', 'Artist tour dates', 'Venue and ticket details'];
      case 'Seasonal Collections':
        return ['Seasonal features', 'Holiday collections', 'Year in review'];
      case 'Artist Spotlight':
        return ['Featured artist', 'Essential albums', 'Verified discography'];
      default:
        return [];
    }
  }
}

const _browseDestinations = <_BrowseDestination>[
  _BrowseDestination('Latest Songs', 'Songs released in the last 30 days on your regional chart.', 'music-note'),
  _BrowseDestination('New Releases', 'Albums released in the last 30 days on your regional chart.', 'disc-3'),
  _BrowseDestination('Trending Songs', 'Tracks trending in a defined region and time window.', 'refresh'),
  _BrowseDestination('Daily Top 100', 'Daily top tracks from a verified chart source for your region.', 'star'),
  _BrowseDestination('Coming Soon', 'Upcoming releases with confirmed release metadata.', 'calendar'),
  _BrowseDestination('Music Videos', 'Music videos from channel owners verified by Breezze.', 'video'),
  _BrowseDestination('Charts', 'Global, regional and genre charts with source attribution.', 'grid'),
  _BrowseDestination('Browse by Genre', 'Explore catalog music by genre and subgenre.', 'compass'),
  _BrowseDestination('Moods & Activities', 'Curated listening collections for moods and activities.', 'favorite'),
  _BrowseDestination('City Charts', 'City-level charts backed by verified regional data.', 'globe'),
  _BrowseDestination('Upcoming Concerts', 'Upcoming concerts and festivals with source-linked event details.', 'calendar'),
  _BrowseDestination('Seasonal Collections', 'Time-limited music collections and seasonal features.', 'disc-3'),
  _BrowseDestination('Artist Spotlight', 'Editorial artist features backed by catalog metadata.', 'user-round'),
];

class _BrowseCollectionScreen extends ConsumerStatefulWidget {
  final _BrowseDestination destination;
  const _BrowseCollectionScreen({required this.destination});

  @override
  ConsumerState<_BrowseCollectionScreen> createState() => _BrowseCollectionScreenState();
}

class _BrowseCollectionScreenState extends ConsumerState<_BrowseCollectionScreen> {
  static const _genres = ['Afrobeats','Bongo Flava','Amapiano','Gospel','Hip-Hop','R&B','Jazz','Electronic','Pop','Rock','Soul','Dancehall'];
  static const _moods = ['Focus','Workout','Chill','Party','Sleep','Commute','Feel good','Romance','Meditation','Running','Study','Driving'];
  String _selected = '';
  List<BzTrack> _tracks = [];
  bool _loading = false;
  String? _error;
  int _generation = 0;
  List<Map<String, dynamic>> _catalogItems = [];
  String? _catalogSource;
  String? _catalogError;
  String? _catalogTerritory;
  DateTime? _catalogFetchedAt;

  bool get _latestSongs => widget.destination.title == 'Latest Songs';
  bool get _appleChart => widget.destination.title == 'Charts';
  bool get _dailyChart => widget.destination.title == 'Daily Top 100';
  bool get _appleReleases => widget.destination.title == 'New Releases';
  bool get _videoFeed => widget.destination.title == 'Music Videos';
  bool get _concertFeed => widget.destination.title == 'Upcoming Concerts';
  bool get _liveProviderCatalog => _latestSongs || _appleChart || _dailyChart || _appleReleases || _videoFeed || _concertFeed;

  bool get _genre => widget.destination.title == 'Browse by Genre';
  bool get _mood => widget.destination.title == 'Moods & Activities';
  bool get _searchable => _genre || _mood;
  List<String> get _choices => _genre ? _genres : _moods;

  @override
  void initState() {
    super.initState();
    if (_searchable) {
      _selected = _choices.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(_selected);
      });
    } else if (_liveProviderCatalog) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadCatalog();
      });
    }
  }

  Future<void> _loadCatalog() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _catalogError = null;
      _catalogItems = [];
    });
    try {
      final api = ref.read(authSessionProvider.notifier).api;
      final configuredTerritory = ref.read(outboxTerritoryProvider).toLowerCase();
      final territory = configuredTerritory.length == 2 && configuredTerritory != 'ww'
          ? configuredTerritory
          : 'us';
      final data = _latestSongs
          ? await api.discoveryLatestSongs(country: territory)
          : _appleReleases
          ? await api.discoveryNewReleases(country: territory)
          : _dailyChart
              ? await api.discoveryDailyTop100(country: territory)
              : _appleChart
                  ? await api.discoverySongsChart(country: territory)
                  : _videoFeed
                  ? await api.discoveryMusicVideos()
                  : await api.discoveryConcerts(country: territory);
      if (!mounted || generation != _generation) return;
      final rawItems = data['items'];
      setState(() {
        _catalogItems = rawItems is List
            ? rawItems.whereType<Map>().map((item) =>
                item.map((key, value) => MapEntry(key.toString(), value))).toList()
            : [];
        _catalogSource = data['source'] as String?;
        _catalogTerritory = data['territory'] as String? ??
            (_videoFeed ? null : territory.toUpperCase());
        _catalogFetchedAt = DateTime.tryParse(data['fetchedAt'] as String? ?? '');
        _catalogError = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _catalogError = 'The ${widget.destination.title.toLowerCase()} provider could not be reached. Try again in a moment.';
        _loading = false;
      });
    }
  }

  Future<void> _openCatalogItem(Map<String, dynamic> item) async {
    final itemId = item['id']?.toString();
    final title = item['title'] as String? ?? 'Untitled';
    final artist = item['artist'] as String? ?? 'Unknown artist';
    final artwork = item['artworkUrl'] as String?;
    if (_appleReleases && itemId != null &&
        RegExp(r'^[0-9]{1,20}$').hasMatch(itemId)) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AppleAlbumCatalogScreen(
          albumId: itemId, title: title, artist: artist,
          artworkUrl: artwork, appleUrl: item['url'] as String?,
        ),
      ));
      return;
    }
    if ((_latestSongs || _appleChart || _dailyChart) && itemId != null) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TrackDetailScreen(
          track: TrackInfo(
            id: 'bz:apple_catalog:$itemId',
            title: title, artist: artist,
            artworkUrl: artwork, duration: Duration.zero,
          ),
          origin: 'new',
        ),
      ));
      return;
    }
    if (_videoFeed && itemId != null) {
      await ref.read(playerControllerProvider.notifier).pause();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => OfficialMusicVideoScreen(
          videoId: itemId,
          title: title,
          artist: artist,
          artworkUrl: artwork,
        ),
      ));
      return;
    }
    if (!mounted) return;
    // Event details remain in Breezze; a ticket link is user-selected.
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(artist),
              if (item['venue'] is String)
                Text('Venue: ' + item['venue'].toString()),
              if (item['city'] is String)
                Text('City: ' + item['city'].toString()),
              if (item['date'] is String)
                Text('Date: ' + item['date'].toString()),
              const SizedBox(height: 16),
              if (item['url'] is String)
                TextButton.icon(
                  icon: const BzSvgIcon(name: 'arrow-up-right'),
                  label: const Text('Official event details'),
                  onPressed: () async {
                    final uri = Uri.tryParse(item['url'] as String);
                    if (uri == null || uri.scheme != 'https') return;
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _search(String choice) async {
    final generation = ++_generation;
    setState(() {
      _selected = choice;
      _loading = true;
      _error = null;
      _tracks = [];
    });
    try {
      final result = await ref.read(catalogSourceProvider).search('$choice music');
      if (!mounted || generation != _generation) return;
      if (result is ProviderOk<List<ProviderTrack>>) {
        setState(() {
          _tracks = result.value.map((track) => BzTrack(
            id: track.breezzeTrackId,
            title: track.title,
            artist: track.artist,
            artworkUrl: track.artworkUrl,
            duration: track.duration,
          )).toList();
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _error = 'The connected music source could not return search results.';
        });
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach the music source. Check your connection and retry.';
      });
    }
  }

  Future<void> _play(int index) async {
    if (_tracks.isEmpty) return;
    final selected = _tracks[index];
    if (!canQueueTrackId(selected.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This result is catalogue metadata only. Native playback is not available from this source.')),
        );
      }
      return;
    }
    final playableTracks = _tracks
        .where((track) => canQueueTrackId(track.id))
        .toList();
    final queue = [for (final track in playableTracks) TrackInfo(
      id: track.id, title: track.title, artist: track.artist,
      artworkUrl: track.artworkUrl, duration: track.duration,
    )];
    final queueIndex = playableTracks.indexWhere((track) => track.id == selected.id);
    if (queueIndex < 0) return;
    await ref.read(playerControllerProvider.notifier).playTrack(
      trackId: selected.id,
      queue: queue,
      startIndex: queueIndex,
      origin: 'browse',
      sourceContext: widget.destination.title + ': ' + _selected,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ref.watch(downloadProgressProvider);
    return Scaffold(
      backgroundColor: theme.bzBackground,
      appBar: AppBar(
        title: Text(widget.destination.title),
        leading: IconButton(
          tooltip: 'Back to New',
          icon: const BzSvgIcon(name: 'chevron-left'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: _liveProviderCatalog
                ? _appleCatalogContent(theme)
                : _searchable
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.destination.description, style: theme.textTheme.bodyMedium),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [for (final choice in _choices)
                                BzFilterPill(
                                  label: choice,
                                  active: _selected == choice,
                                  onTap: () => _search(choice),
                                )],
                            ),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.bzSurface1,
                                borderRadius: BorderRadius.circular(BzRadius.card),
                                border: Border.all(color: theme.bzSeparator),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  BzSvgIcon(name: 'info', size: 18, color: theme.bzText2),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(
                                    'These are track-search matches from the connected source. They are not verified editorial playlists, mood classifications or official genre charts.',
                                    style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                                  )),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(_genre ? 'Genre search matches' : 'Mood search matches', style: theme.textTheme.titleMedium),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _loading
                            ? ListView.separated(
                                padding: const EdgeInsets.all(16),
                                itemCount: 6,
                                separatorBuilder: (_, __) => const SizedBox(height: 14),
                                itemBuilder: (_, __) => const BzSkeletonTrackRow(),
                              )
                            : _error != null
                                ? _MessageState(
                                    icon: 'wifi-off', title: 'Music source unavailable',
                                    message: _error!, onRetry: () => _search(_selected),
                                  )
                                : _tracks.isEmpty
                                    ? _MessageState(
                                        icon: 'music-note', title: 'No matches found',
                                        message: 'Try another selection or retry this search.',
                                        onRetry: () => _search(_selected),
                                      )
                                    : ListView.builder(
                                        padding: EdgeInsets.fromLTRB(0, 8, 0, BzBreakpoints.bottomClearance(context, compact: 220)),
                                        itemCount: _tracks.length,
                                        itemBuilder: (context, index) {
                                          final track = _tracks[index];
                                          final download = progress[track.id];
                                          return ListTile(
                                            leading: track.artworkUrl == null
                                                ? BzBnoteMark(size: 48, color: theme.bzText2)
                                                : ClipRRect(
                                                    borderRadius: BorderRadius.circular(BzRadius.artwork),
                                                    child: Image.network(
                                                      track.artworkUrl!, width: 48, height: 48, fit: BoxFit.cover,
                                                      errorBuilder: (_, __, ___) => BzBnoteMark(size: 48, color: theme.bzText2),
                                                    ),
                                                  ),
                                            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                            subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                                            trailing: download != null
                                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                                                : IconButton(
                                                    tooltip: 'Download',
                                                    icon: const BzSvgIcon(name: 'download', size: 20),
                                                    onPressed: !canRequestOfflineDownload(track.id)
                                                        ? null
                                                        : () => ref.read(downloadProgressProvider.notifier).download(track),
                                                  ),
                                            onTap: () => _play(index),
                                          );
                                        },
                                      ),
                      ),
                    ],
                  )
                : _unavailable(theme),
          ),
        ),
      ),
    );
  }

  Widget _appleCatalogContent(ThemeData theme) {
    final isReleaseFeed = _appleReleases || _latestSongs;
    final isVideoFeed = _videoFeed;
    final isConcertFeed = _concertFeed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.destination.description, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              if (_catalogSource != null || _catalogTerritory != null) ...[
                const SizedBox(height: 5),
                Text(
                  '${_catalogSource ?? 'Catalog source'} • ${_catalogTerritory ?? 'Territory'}'
                  '${_catalogFetchedAt == null ? '' : ' • Updated ${_catalogFetchedAt!.toLocal()}'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: 8,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, __) => const BzSkeletonTrackRow(),
                )
              : _catalogError != null
                  ? _MessageState(
                      icon: 'wifi-off',
                      title: 'Catalog unavailable',
                      message: _catalogError!,
                      onRetry: _loadCatalog,
                    )
                  : _catalogItems.isEmpty
                      ? _MessageState(
                          icon: 'music-note',
                          title: 'No catalog entries',
                          message: 'The source returned no entries for this territory.',
                          onRetry: _loadCatalog,
                        )
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(12, 4, 12, BzBreakpoints.bottomClearance(context, compact: 220)),
                          itemCount: _catalogItems.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: theme.bzSeparator),
                          itemBuilder: (context, index) {
                            final item = _catalogItems[index];
                            final artwork = item['artworkUrl'];
                            final title = item['title'] as String? ?? 'Untitled';
                            final artist = item['artist'] as String? ?? 'Unknown artist';
                            final rank = item['rank'];
                            final meta = isReleaseFeed
                                ? (item['releaseDate'] ?? 'Release date not supplied').toString()
                                : isVideoFeed
                                    ? (item['publishedAt'] ?? 'Publication date not supplied').toString()
                                    : isConcertFeed
                                        ? [
                                            if (item['date'] is String) item['date'],
                                            if (item['venue'] is String) item['venue'],
                                            if (item['city'] is String) item['city'],
                                          ].join(' · ')
                                        : '';
                            return ListTile(
                              leading: SizedBox(
                                width: 52,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (rank is int)
                                      SizedBox(
                                        width: 20,
                                        child: Text(rank.toString(), style: theme.textTheme.labelMedium?.copyWith(color: theme.bzText2)),
                                      ),
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(BzRadius.artwork),
                                        child: artwork is String
                                            ? Image.network(
                                                artwork,
                                                width: 48,
                                                height: 48,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) => BzBnoteMark(size: 44, color: theme.bzText2),
                                              )
                                            : BzBnoteMark(size: 44, color: theme.bzText2),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                isConcertFeed
                                    ? (meta.isEmpty ? artist : meta)
                                    : isVideoFeed
                                        ? '$artist • $meta'
                                        : isReleaseFeed
                                            ? '$artist • $meta'
                                            : artist,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: isVideoFeed
                                    ? 'Watch official video'
                                    : isConcertFeed
                                        ? 'Open event details'
                                        : 'View details in Breezze',
                                icon: const BzSvgIcon(name: 'arrow-up-right', size: 19),
                                onPressed: () => _openCatalogItem(item),
                              ),
                              onTap: () => _openCatalogItem(item),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _unavailable(ThemeData theme) {
    final destination = widget.destination;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: theme.bzSurface1,
            borderRadius: BorderRadius.circular(BzRadius.card),
            border: Border.all(color: theme.bzSeparator),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 54, height: 54,
                decoration: BoxDecoration(color: theme.bzSurface2, borderRadius: BorderRadius.circular(15)),
                alignment: Alignment.center,
                child: BzSvgIcon(name: destination.icon, size: 27, color: theme.bzAccent),
              ),
              const SizedBox(height: 18),
              Text(destination.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(destination.description, style: theme.textTheme.bodyMedium?.copyWith(color: theme.bzText2)),
              const SizedBox(height: 22),
              Row(children: [
                BzSvgIcon(name: 'info', size: 19, color: theme.bzAccent),
                const SizedBox(width: 9),
                Text('Not available yet', style: theme.textTheme.titleMedium),
              ]),
              const SizedBox(height: 10),
              Text(destination.availabilityMessage, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(
                'Breezze will publish this section only after its source, territory, metadata and usage permissions can be verified.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.bzText2),
              ),
            ],
          ),
        ),
        if (destination.previewSections.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('What belongs in this section', style: theme.textTheme.titleLarge),
          const SizedBox(height: 10),
          for (final item in destination.previewSections)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                BzSvgIcon(name: 'info', size: 17, color: theme.bzText2),
                const SizedBox(width: 10),
                Expanded(child: Text(item, style: theme.textTheme.bodyMedium)),
              ]),
            ),
        ],
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Back to Browse'),
        ),
      ],
    );
  }
}

/// Browse selection pill — capsule (spec --radius-pill), solid text1 fill
/// when active, surface2 when not. Mirrors the Library and Search pills.
