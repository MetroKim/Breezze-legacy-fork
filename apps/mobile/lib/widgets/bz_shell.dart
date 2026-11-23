import 'package:breezze_audio_contracts/audio_contracts.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bz_brand_icons.dart';
import 'bz_playback_scrubber.dart';
import '../features/browse/browse_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/player/now_playing_screen.dart';
import '../features/player/player_controller.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/account_screen.dart';

/// Breezze's four-destination shell. Downloads live inside Library and
/// Settings are reached from the profile surface; neither is a top-level tab.
class BreezzeShell extends StatelessWidget {
  const BreezzeShell({super.key});

  @override
  Widget build(BuildContext context) => const _BreezzeRoot();
}

class _BreezzeRoot extends StatelessWidget {
  const _BreezzeRoot();

  @override
  Widget build(BuildContext context) => const BzHome();
}

class BzHome extends ConsumerStatefulWidget {
  const BzHome({super.key});

  @override
  ConsumerState<BzHome> createState() => _BzHomeState();
}

class _BzHomeState extends ConsumerState<BzHome> {
  int _index = 0;

  static const _tabs = [
    _TabDestination('Home', 'assets/icons/home.svg'),
    _TabDestination('Browse', 'assets/icons/new.svg'),
    _TabDestination('Library', 'assets/icons/library.svg'),
    _TabDestination('Search', 'assets/icons/search.svg'),
  ];

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(homeTabHintProvider, (previous, next) {
      if (next >= 0 && next < _tabs.length) {
        if (next != _index) setState(() => _index = next);
        ref.read(homeTabHintProvider.notifier).state = -1;
      }
    });
    final player = ref.watch(playerControllerProvider);
    final hasPlayer = player.playbackState != PlaybackState.idle;

    final pages = IndexedStack(
      index: _index,
      children: const [
        HomeScreen(),
        BrowseScreen(),
        LibraryScreen(),
        SearchScreen(),
      ],
    );

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final expanded = constraints.maxWidth >= BzBreakpoints.medium;
          if (!expanded) return pages;

          // Apple Music 7.0 desktop: content fills the pane and the glass
          // player pill floats above it, anchored bottom: 20, centered,
          // auto-width — never a docked full-width bar (spec §4.1).
          return Row(
            children: [
              _DesktopNavigation(
                index: _index,
                tabs: _tabs,
                onChanged: (i) => setState(() => _index = i),
                onOpenAccount: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                ),
                onOpenSettings: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: BzBreakpoints.contentMaxWidth,
                        ),
                        child: pages,
                      ),
                    ),
                    if (hasPlayer)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 20,
                        child: Center(
                          child: _MiniPlayer(onTap: _openNowPlaying),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width >= BzBreakpoints.medium
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                // Floating Liquid Glass bottom chrome: wider margins so the
                // capsule tab bar and mini-player read as undocked layers,
                // not edge-to-edge bars (Apple Music 7.0 pattern).
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasPlayer) ...[
                      _MiniPlayer(onTap: _openNowPlaying),
                      const SizedBox(height: 8),
                    ],
                    _TabBar(
                      index: _index,
                      tabs: _tabs,
                      onChanged: (i) => setState(() => _index = i),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  void _openNowPlaying() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NowPlayingScreen(),
        fullscreenDialog: true,
      ),
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  final int index;
  final List<_TabDestination> tabs;
  final ValueChanged<int> onChanged;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenSettings;

  const _DesktopNavigation({
    required this.index,
    required this.tabs,
    required this.onChanged,
    required this.onOpenAccount,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 224,
      decoration: BoxDecoration(
        color: theme.bzSurface1,
        border: Border(
          right: BorderSide(color: theme.bzSeparator, width: 0.5),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 28),
                child: Row(
                  children: [
                    BzBnoteMark(size: 30, color: theme.bzText1),
                    const SizedBox(width: 10),
                    Text(
                      'Breezze',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                      ),
                    ),
                  ],
                ),
              ),
              for (var i = 0; i < tabs.length; i++)
                _DesktopTabButton(
                  destination: tabs[i],
                  active: index == i,
                  onTap: () => onChanged(i),
                ),
              const Spacer(),
              Divider(color: theme.bzSeparator),
              _DesktopUtilityLink(
                label: 'Account',
                iconName: 'user-round',
                onTap: onOpenAccount,
              ),
              _DesktopUtilityLink(
                label: 'Settings',
                iconName: 'settings',
                onTap: onOpenSettings,
              ),
              const SizedBox(height: 10),
              Text(
                'YOUR MUSIC. YOUR SPACE.',
                style: TextStyle(
                  color: theme.bzText2,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopUtilityLink extends StatelessWidget {
  final String label;
  final String iconName;
  final VoidCallback onTap;

  const _DesktopUtilityLink({
    required this.label,
    required this.iconName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(BzRadius.button),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                BzSvgIcon(name: iconName, size: 21, color: theme.bzText2),
                const SizedBox(width: 13),
                Text(label,
                    style: TextStyle(color: theme.bzText2, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopTabButton extends StatelessWidget {
  final _TabDestination destination;
  final bool active;
  final VoidCallback onTap;

  const _DesktopTabButton({
    required this.destination,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active ? theme.bzAccent : theme.bzText2;
    // Selected rows use a quiet 5% tint fill with an 8px radius —
    // never a filled capsule at rest (spec: sidebar selection contract).
    final activeFill = theme.bzText1.withValues(alpha: 0.05);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        selected: active,
        label: destination.label,
        child: Tooltip(
          message: destination.label,
          child: Material(
            color: active ? activeFill : Colors.transparent,
            borderRadius: BorderRadius.circular(BzRadius.button),
            child: InkWell(
              borderRadius: BorderRadius.circular(BzRadius.button),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      destination.asset,
                      width: 21,
                      height: 21,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    ),
                    const SizedBox(width: 13),
                    Text(
                      destination.label,
                      style: TextStyle(
                        color: color,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabDestination {
  final String label;
  final String asset;
  const _TabDestination(this.label, this.asset);
}

class _MiniPlayer extends ConsumerWidget {
  final VoidCallback onTap;

  const _MiniPlayer({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final theme = Theme.of(context);
    final playing = player.playbackState == PlaybackState.playing;
    final track = player.currentTrack;
    final progress = player.duration > Duration.zero
        ? (player.position.inMilliseconds / player.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -150) onTap();
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(BzRadius.capsule),
          onTap: onTap,
          child: BzGlassContainer(
          radius: BzRadius.capsule,
          blur: 24,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    HeroMode(
                      enabled: track != null && !MediaQuery.disableAnimationsOf(context),
                      child: Hero(tag: 'now-playing-art:${track?.id}', child:
                    ClipRRect(
                      borderRadius: BorderRadius.circular(BzRadius.artwork),
                      child: track?.artworkUrl != null
                          ? Image.network(
                              track!.artworkUrl!,
                              width: 42,
                              height: 42,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _MiniArtwork(color: theme.bzText2),
                            )
                          : _MiniArtwork(color: theme.bzText2),
                    ))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            track?.title ?? 'Now Playing',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            player.playbackState == PlaybackState.failed
                                ? 'Audio unavailable'
                                : track?.artist ?? 'Breezze',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: BzType.footnote,
                              color: theme.bzText2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous track',
                      onPressed: controller.previous,
                      icon: BzSvgIcon(
                        name: 'skip-previous',
                        color: theme.bzText1,
                        size: 20,
                      ),
                    ),
                    _PlayerIconButton(
                      asset: playing
                          ? 'assets/icons/pause.svg'
                          : 'assets/icons/play.svg',
                      label: playing ? 'Pause' : 'Play',
                      onPressed: controller.togglePlayPause,
                    ),
                    _PlayerIconButton(
                      asset: 'assets/icons/skip-next.svg',
                      label: 'Next track',
                      onPressed: controller.next,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Scrubber (blueprint §5.2): pointer-drag seek, not just a
                // passive indicator. The drag fraction dispatches seekTo
                // through the player store — UI never touches the engine.
                BzPlaybackScrubber(
                  progress: progress,
                  enabled: player.duration > Duration.zero,
                  onSeek: (fraction) => controller.seekTo(
                    Duration(
                      milliseconds:
                          (fraction * player.duration.inMilliseconds).toInt(),
                    ),
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

/// Draggable progress strip on the mini-player pill. Tap or drag seeks;
/// the fill uses the accent token (action/state color) per the accent
/// discipline contract. Disabled while duration is unknown.
class _MiniArtwork extends StatelessWidget {
  final Color color;
  const _MiniArtwork({required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 42,
        height: 42,
        child: Center(
          child: SvgPicture.asset(
            'assets/icons/music-note.svg',
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
      );
}

class _PlayerIconButton extends StatelessWidget {
  final String asset;
  final String label;
  final VoidCallback onPressed;

  const _PlayerIconButton({
    required this.asset,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: SvgPicture.asset(
        asset,
        width: 21,
        height: 21,
        colorFilter: ColorFilter.mode(
          Theme.of(context).bzText1,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final int index;
  final List<_TabDestination> tabs;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.index,
    required this.tabs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (details) => _selectFromGlobalPosition(
            details.globalPosition,
            context,
          ),
          onLongPressMoveUpdate: (details) => _selectFromGlobalPosition(
            details.globalPosition,
            context,
          ),
          child: BzGlassContainer(
            radius: BzRadius.capsule,
            blur: 16,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _TabButton(
                        destination: tabs[i],
                        active: i == index,
                        onTap: () => onChanged(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _selectFromGlobalPosition(Offset globalPosition, BuildContext context) {
    // Long-press tab selection must use the tab bar's actual render bounds,
    // not the screen width (which differs in insets/split-screen/desktop).
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || renderObject.size.width <= 0) return;
    final x = renderObject.globalToLocal(globalPosition).dx;
    final fraction = (x / renderObject.size.width).clamp(0.0, 0.999999);
    onChanged((fraction * tabs.length).floor());
  }
}

class _TabButton extends StatelessWidget {
  final _TabDestination destination;
  final bool active;
  final VoidCallback onTap;

  const _TabButton({
    required this.destination,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active ? theme.bzAccent : theme.bzText2;

    return Semantics(
      button: true,
      selected: active,
      label: destination.label,
      child: Tooltip(
        message: destination.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(BzRadius.button),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: BzMotion.fastMs),
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: active ? theme.bzSurface2 : Colors.transparent,
                      borderRadius: BorderRadius.circular(BzRadius.button),
                    ),
                    alignment: Alignment.center,
                    child: SvgPicture.asset(
                      destination.asset,
                      width: 22,
                      height: 22,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    destination.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: color,
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
