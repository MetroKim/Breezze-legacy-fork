import 'dart:async';
import '../../app/appearance_controller.dart';

import 'package:material_ui/material_ui.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:breezze_design_system/breezze_design_system.dart';
import '../../core/api/breezze_api.dart';
import '../../features/onboarding/onboarding_controller.dart';

import '../../core/auth/auth_session.dart';
import '../../core/audio/just_audio_engine_adapter.dart';
import '../../core/audio/audio_service_bridge.dart';
import '../../core/audio/background_audio.dart';
import '../../core/database/migrate_to_drift.dart';
import '../../core/database/outbox_sync_service.dart';
import '../../features/player/player_controller.dart';
import '../../features/authentication/auth_screen.dart';
import '../../features/onboarding/onboarding_flow.dart';
import 'bz_shell.dart';

/// Auth gate: auth screen until signed in, then the shell. On
/// sign-in, queued offline ops drain to the backend. First-time
/// users (no saved backend preferences) see onboarding over the
/// live shell; finishing or skipping dismisses it and sets the
/// sync territory from the chosen country.
class BreezzeAppRoot extends ConsumerStatefulWidget {
  const BreezzeAppRoot({super.key});

  @override
  ConsumerState<BreezzeAppRoot> createState() => _BreezzeAppRootState();
}

class _BreezzeAppRootState extends ConsumerState<BreezzeAppRoot> with WidgetsBindingObserver {
  bool _showOnboarding = false;
  int _accountVersion = 0;
  GlobalKey? _shellKey;
  ProviderContainer? _container;
  JustAudioEngineAdapter? _audioEngine;
  BackgroundAudioBridge? _backgroundBridge;
  late final Future<Color?> _brandSeedFuture;

  @override
  void initState() {
    super.initState();
    _brandSeedFuture = _readBrandIconPalette();
    WidgetsBinding.instance.addObserver(this);
    _container = ProviderScope.containerOf(context, listen: false);
    _audioEngine = JustAudioEngineAdapter();
    _container!.read(playerControllerProvider.notifier).attachEngine(_audioEngine!);
    unawaited(_startBackgroundAudio());
    unawaited(migrateJsonStoresToDrift(_container!));
    unawaited(_container!.read(authSessionProvider.notifier).restoreSession());
    ref.listenManual(authSessionProvider, (prev, next) {
      final before = prev is AuthSignedIn ? prev.userId : null;
      final after = next is AuthSignedIn ? next.userId : null;
      if (before != after) {
        _accountVersion++;
        _showOnboarding = false;
        _shellKey = GlobalKey();
        ref.invalidate(onboardingProvider);
        ref.read(outboxTerritoryProvider.notifier).state = 'WW';
      }
      if (prev is AuthSignedIn && before != after) {
        unawaited(ref.read(playerControllerProvider.notifier).stop());
      }
      if (next is AuthSignedIn && before != after) {
        // Replay offline ops now that a session exists.
        unawaited(ref.read(outboxSyncProvider).drainIfSignedIn());

        // First-time check: has the backend saved preferences yet?
        _checkOnboardingNeeded(_accountVersion);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.read(authSessionProvider) is AuthSignedIn) {
      unawaited(ref.read(outboxSyncProvider).drainIfSignedIn());
    }
  }

  Future<void> _startBackgroundAudio() async {
    try {
      final bridge = await startBackgroundAudio(_container!);
      if (!mounted) {
        await bridge.stop();
        return;
      }
      _backgroundBridge = bridge;
      _container!.read(backgroundBridgeProvider.notifier).state = bridge;
      // Start the single state-to-media-session subscription once for the
      // app lifetime, not every time the authenticated shell is recreated.
      _container!.read(backgroundSyncProvider);
    } catch (error) {
      debugPrint('Breezze background media session unavailable: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_backgroundBridge?.stop() ?? Future<void>.value());
    _container?.read(playerControllerProvider.notifier).detachEngine();
    _audioEngine?.dispose();
    super.dispose();
  }

  Future<void> _checkOnboardingNeeded(int version) async {
    final api = ref.read(authSessionProvider.notifier).api;
    try {
      final preferences = await api.onboardingPreferences();
      if (!mounted || version != _accountVersion) return;
      ref.read(outboxTerritoryProvider.notifier).state =
          preferences['country'] as String? ?? 'WW';
    } on BreezzeApiException catch (error) {
      if (mounted && version == _accountVersion && error.code == 'HTTP_404') {
        setState(() => _showOnboarding = true);
      }
    } catch (_) {
      // A listener can still open the cached library while offline.
    }
  }

  Future<Color?> _readBrandIconPalette() async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        const AssetImage('assets/icons/launcher.png'),
        maximumColorCount: 16,
      );
      // The approved Breezze launcher is monochrome; the theme's contrast
      // policy will keep the neutral fallback for an achromatic palette.
      return palette.vibrantColor?.color ?? palette.dominantColor?.color;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authSessionProvider);

    // Keep one MaterialApp/Navigator above every auth state. Previously the
    // signed-out gate rendered AuthScreen before the shell's nested
    // MaterialApp existed, leaving login/register without app navigation,
    // theme and inherited Material widgets.
    return FutureBuilder<Color?>(
      future: _brandSeedFuture,
      builder: (context, palette) => MaterialApp(
      title: 'Breezze',
      debugShowCheckedModeBanner: false,
      themeMode: ref.watch(appearanceProvider).valueOrNull ?? ThemeMode.system,
      theme: bzLightTheme(brandSeed: palette.data),
      darkTheme: bzDarkTheme(brandSeed: palette.data),
      home: Builder(
        builder: (context) {
          if (auth is AuthUninitialized) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          // Signed-out listeners can browse the free public catalogue and
          // reach the account gateway without being forced through sign-in.
          // Backend-owned libraries and downloads remain session-scoped.
          if (auth is AuthSignedIn || auth is AuthSignedOut ||
              auth is AuthError || auth is AuthSigningIn) {
            final shell = KeyedSubtree(
              key: _shellKey,
              child: const BreezzeShell(),
            );
            if (auth is AuthSignedIn && _showOnboarding) {
              return Stack(
                children: [
                  shell,
                  Positioned.fill(
                    child: Scaffold(
                      backgroundColor:
                          Theme.of(context).scaffoldBackgroundColor,
                      body: Stack(
                        children: [
                          OnboardingFlow(onComplete: _dismissOnboarding),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: SafeArea(
                              child: TextButton(
                                onPressed: _dismissOnboarding,
                                child: const Text('Skip'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            return shell;
          }

          return const AuthScreen();
        },
      ),
      ),
    );
  }

  void _dismissOnboarding() => setState(() => _showOnboarding = false);
}
