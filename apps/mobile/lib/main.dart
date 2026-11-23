import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/bootstrap.dart';
import 'core/auth/auth_session.dart';
import 'core/auth/secure_session_storage.dart';
import 'core/database/database_providers.dart';
import 'features/player/player_controller.dart';
import 'features/player/playback_session_client.dart';
import 'widgets/breezze_app_root.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Only the publishable key is embedded. Never ship the service-role key.
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL',
      defaultValue: 'https://djwvyjtebmsavhcrmhxf.supabase.co'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY',
      defaultValue: 'sb_publishable_ZloCmmQPo86OqHbH3Yqgsw_xZGPqSi3'),
    authOptions: kIsWeb
        ? const FlutterAuthClientOptions()
        : FlutterAuthClientOptions(localStorage: BreezzeSecureSessionStorage()),
  );
  // Register the just_audio Linux/Windows implementations before the
  // global AudioPlayer is constructed by BreezzeAppRoot.
  JustAudioMediaKit.ensureInitialized();

  runApp(
    ProviderScope(
      overrides: [
        playbackSessionClientProvider.overrideWith(
          (ref) => ApiPlaybackSessionClient(
            ref.read(authSessionProvider.notifier).api,
          ),
        ),
        playbackResolverProvider.overrideWith(
          (ref) => ref.watch(liveResolverProvider),
        ),
        playHistoryReporterProvider.overrideWith((ref) {
          return (track) async {
            final auth = ref.read(authSessionProvider);
            if (auth is! AuthSignedIn) return;

            var catalogTrackId = track.id;
            if (catalogTrackId.startsWith('bz:')) {
              final mapped = await ref
                  .read(catalogIdMapDaoProvider)
                  .lookup(catalogTrackId);
              if (mapped == null) return;
              catalogTrackId = mapped;
            }

            await ref
                .read(authSessionProvider.notifier)
                .api
                .recordRecent(catalogTrackId);
          };
        }),
      ],
      child: const BreezzeAppRoot(),
    ),
  );
}
