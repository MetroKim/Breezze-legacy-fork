# Breezze — Spotify-inspired discovery and personalization (research + implementation)

Breezze's recommendation engine is independently designed, based on publicly described techniques and transparent user-control principles. It is **not** Spotify's proprietary model or a claim of model-level parity.

## Research findings

1. Spotify's publicly described Home architecture uses **two stages**: generating candidate tracks/artists/collections and ranking them into shelves. Recommenders must balance relevance with variety rather than merely sorting by plays. Source: [Spotify Engineering — Rise of ML Models on Home](https://www.engineering.atspotify.com/2021/11/the-rise-and-lessons-learned-of-ml-models-to-personalize-content-on-home-part-i).
2. Spotify uses a **taste profile** that reflects interactions, follows, listening, favorites and recommendation feedback. Following an artist helps new-release discovery and recommendations. Sources: [Spotify — Understanding Recommendations](https://www.spotify.com/uk/safetyandprivacy/understanding-recommendations) and [Spotify Support — Following artists](https://support.spotify.com/us/article/follow-artists-podcasts-and-shows/).
3. Separate **short-term and long-term interests** help balance recent moods and stable music taste; Spotify Research publicly describes 1-week, 1-month, and 6-month representations. Source: [Generalized User Representations (2025)](https://research.atspotify.com/2025/9/generalized-user-representations-for-large-scale-recommendations).
4. Recommendation ranking should optimize durable user satisfaction, discovery, diversity, and artist fairness—not just clicks or repeated plays. Spotify published research on contextual-bandit calibration and cross-shelf balancing. Source: [Calibrated Recommendations (2025)](https://research.atspotify.com/2025/9/calibrated-recommendations-with-contextual-bandits-on-spotify-homepage).
5. Flutter requires both translated strings and localization delegates to truly localize the UI; a language preference alone is **not full translation support**. Source: [Flutter internationalization](https://docs.flutter.dev/ui/internationalization).

## Product rules (binding)

- Breezze **requires login** to enter any of the four tabs, including Home. Google is configured and Apple stays visible but disabled while activation is pending. Custom Flutter auth UI only.
- English (`en`) is the initial default. The Settings language selector exposes a broad catalog and stores the user's choice. Native Flutter controls can localize to supported locales. **Breezze-specific strings require reviewed translations**; do not market unsupported languages as fully translated.
- Artist Follow and Unfollow use the real authenticated account's library API. Followed artists must appear in Library even when zero tracks are saved.
- Following is a strong explicit recommendation signal. Unfollowing removes its *follow-specific* weight; previous legitimate listening/favorites may continue to affect recommendations.
- Artist and track metadata are **not** media rights. Before publishing any full-track recommendation, the rights filter validates available full-stream rights for the trusted edge territory.
- No purchase, subscription, ad, social feed, radio, fake streaming source, or hidden tracking.

## What is implemented in the draft PR

- Mandatory Supabase auth gate and disabled-but-visible Apple logo; removed unauthenticated Browse shortcut.
- Language catalog, searchable Settings language picker, persisted per-account Supabase `profiles.language` plus local offline fallback, `MaterialApp.locale` and SDK localization delegates.
- Prisma `UserFollowedArtist.artistName` migration and authenticated artist listing. Follow passes the artist's display name from the artist screen.
- Library artists list includes followed entries independent of saved songs, with followed artists sorted first.
- Recommendation candidate generation now uses followed canonical artist IDs and names, preferred/onboarding artist names, favorites, and **server-verified listening events**. Candidate tracks are ordered by album release date when available, artist-interleaved, and checked for territory-specific full-stream rights, with a two-tracks-per-artist diversity cap. Followed tracks get a reason of “Because you follow this artist”.
- Home shelves separate “From Artists You Follow” from “Made for You”, followed by recently played and favorites, with no duplicate items between followed and personalized shelves.

## Future improvement gates (NOT claimed implemented)

- Provide full UI translation resources for each displayed locale and an English fallback audit, including RTL layouts and locale-specific search.
- Add search impressions / skip / hide / thumbs-down events with **clear privacy controls**, opt-out, retention limits and authenticated owner isolation. Do not infer explicit dislikes from provider errors.
- Build canonical genre/mood and artist similarity taxonomy for real cross-artist discovery; currently candidate recall primarily finds more songs from known/followed artists.
- Create a verified Release Radar from actual release dates of followed artists and a Daily Mix with constrained diversity, then benchmark content freshness and rights clearance.
- Train/rank from short (week), medium (month), and long-term listening patterns only after sufficient lawful activity data and an appropriate privacy model exist. Benchmark cold start, minority genres, creator coverage, and all-user fairness.
- Validate real session/device testing, two-user row isolation, server playback grants, signed builds, and lifecycle reliability before enabling production routing.

## Verification

- GitHub CI is the code build/test gate. New tests cover followed-artist recommender signals and separation of Home shelves.
- The deployed production app is not switched over by this plan. Keep the auth + recommender changes in draft PR #7 until complete integration, migrations and smoke tests pass.
