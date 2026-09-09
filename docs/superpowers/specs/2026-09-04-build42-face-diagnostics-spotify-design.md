# Build 42 — Face diagnostics + Spotify control

Date: 2026-09-04
Base branch: `jarvis-dev`
Feature branch: `feature/build42-face-diagnostics-spotify`

## Goal

Build 42 has two independent goals:

1. Instrument the front-camera face pipeline so one real-device run can identify whether the current failure is caused by orientation/mirroring, face detection, crop generation, feature-print generation, or capture timing.
2. Add first-class Spotify control to JARVIS so spoken commands can open Spotify, play a requested track, pause/resume, skip next/previous, seek, and read basic player state.

These are implemented as separate components and separate commits so a Spotify regression cannot obscure the face diagnostics.

## 1. Face diagnostics

### Current evidence

Build 41 already proves that explicit front-camera routing works:

- `PhoneCameraService` configures `position=front`.
- A `2316x3088` photo is captured.
- `VisionCaptureService` reports `source=phone_front`.
- `FaceRecognitionTool` receives the image.
- `FaceRecognitionService` then returns no usable face print.

The rear-camera path can successfully enroll the same user, so storage and the basic Vision feature-print pipeline are functional.

### Diagnostic changes

Add instrumentation without changing match thresholds or enrollment semantics.

`PhoneCameraService` logs:

- requested camera position;
- actual device position/name;
- image pixel size;
- `UIImage.imageOrientation`;
- elapsed capture time.

`FaceRecognitionService` logs:

- input image orientation and dimensions;
- normalized image dimensions;
- face-detection elapsed time;
- number of detected faces;
- each detected face bounding box;
- crop dimensions;
- feature-print generation elapsed time and total count;
- total face-pipeline elapsed time.

If the normal pass detects zero faces, run a diagnostic-only orientation probe over the same CGImage using the four principal `CGImagePropertyOrientation` values (`up`, `right`, `left`, `down`) and log the face count for each. The probe must not save a face or change the normal result; its only purpose is root-cause evidence.

No automatic retry, extra delay, threshold change, or alternate orientation will be used as the production result in this build. Build 42 is evidence-gathering first.

### Success criteria

A failed front-camera enrollment produces enough diagnostic output to answer which exact stage failed. Rear-camera enrollment behavior remains unchanged.

## 2. Spotify architecture

### External constraints

Spotify App Remote is used for local playback control because it drives the installed Spotify app and supports play-by-URI, pause/resume, next/previous, seek, shuffle, and player-state reads.

Track-name resolution uses Spotify Web API Search to turn phrases such as `toque Sweet Child O' Mine` into a Spotify track URI.

Authentication uses OAuth Authorization Code with PKCE. The mobile app must not contain a Spotify client secret. Access/refresh tokens are stored in iOS Keychain; the non-secret Spotify Client ID can be stored in JARVIS settings.

The Spotify app must be installed for App Remote control. A Premium account is required for on-demand track playback.

### Components

#### `SpotifyService`

Single main-thread service responsible for:

- checking Spotify installation;
- OAuth PKCE authorization;
- storing and refreshing tokens;
- connecting/disconnecting `SPTAppRemote` according to app lifecycle;
- opening Spotify;
- Web API track search;
- App Remote playback commands;
- basic player-state reads;
- diagnostic logging under category `Spotify`.

It exposes a narrow command-oriented API to the native tool rather than leaking SDK types into the rest of JARVIS.

#### `SpotifyTool`

New Native Tool registered in `NativeToolRegistry`.

Actions:

- `open`
- `connect`
- `play` with optional `query`
- `pause`
- `resume`
- `next`
- `previous`
- `seek` with `seconds`
- `shuffle` with `enabled`
- `status`

Examples of intended natural-language routing:

- `Jarvis, abra o Spotify.`
- `Toque Sweet Child O' Mine.`
- `Pause a música.`
- `Continue.`
- `Pule essa.`
- `Volte a música.`
- `Avance 30 segundos.`
- `Ative o aleatório.`

The model may choose the tool through normal function calling; obvious playback commands may later receive deterministic routing if real-device tests show function-calling latency or ambiguity.

#### `SpotifySettingsView`

Add a small Spotify settings section containing:

- Spotify Client ID text field;
- fixed redirect URI shown read-only;
- connection/authentication status;
- `Conectar Spotify` / `Desconectar` action.

The Client ID is not a secret. Tokens are never shown or stored in `settings.json`.

### Redirect URI

Use a fixed custom callback:

`jarvis-spotify://callback`

Add `jarvis-spotify` to `CFBundleURLTypes` and `spotify` to `LSApplicationQueriesSchemes`.

`JARVISApp.onOpenURL` becomes a dispatcher:

- `jarvis-spotify` callback -> Spotify auth handler;
- existing Meta callback -> Meta Wearables handler.

### Dependency

Add the official `https://github.com/spotify/ios-sdk` package pinned to the current stable release used by this implementation and link product `SpotifyiOS` to the JARVIS target.

### OAuth and token lifecycle

Use Authorization Code + PKCE:

1. Generate verifier, SHA-256 challenge, and CSRF state.
2. Open Spotify authorization with scopes needed for App Remote control.
3. Validate callback state.
4. Exchange authorization code for access + refresh token without a client secret.
5. Store token material in Keychain.
6. Refresh the access token before/after expiry as needed.
7. Assign the current access token to App Remote connection parameters.

If Spotify is unconfigured, unauthenticated, not installed, disconnected, or token refresh fails, the tool returns a short actionable spoken error rather than pretending success.

### Search + play flow

For `play(query)`:

1. Ensure Spotify is configured and authenticated.
2. Search Spotify Web API `GET /v1/search?type=track&limit=5` with the user's query.
3. Select the strongest track match and obtain its Spotify URI.
4. Connect App Remote if necessary.
5. Call App Remote play with the track URI.
6. Return a concise spoken confirmation using only returned metadata (track/artist), without sending Spotify audio/content to the AI model.

Spotify catalog metadata is used only to resolve and confirm playback. It is not stored in JARVIS memory and is not used for model training.

### Audio coexistence

JARVIS currently keeps an active `AVAudioSession` for wake-word/voice chat. Spotify playback and the JARVIS microphone therefore need a real-device coexistence test.

Build 42 will not broadly rewrite audio routing. Spotify diagnostics will log App Remote connection/player state and the current JARVIS audio route. If Spotify is paused or muted by JARVIS's always-on audio session, the next targeted change will add a specific external-media coexistence mode instead of changing all voice behavior preemptively.

### Error handling

- Missing Client ID -> instruct user to configure Spotify in Settings.
- Spotify not installed -> open App Store/Spotify web link only on explicit user action; otherwise report requirement.
- Not authenticated -> request authorization.
- Expired token -> refresh once, then fail clearly if refresh fails.
- Search returns no track -> say no matching track was found.
- App Remote disconnected -> reconnect once; if it still fails, report that Spotify needs to be opened/active.
- Web API 429 -> surface temporary rate-limit message; do not loop.

### Diagnostics

Log only non-sensitive state:

- configured yes/no;
- auth state/token expiry timestamp, never token values;
- App Remote connecting/connected/disconnected/error;
- command name;
- search query length and selected track URI identifier if needed for debugging;
- player state summary;
- elapsed time for search/connect/play.

Do not log access tokens, refresh tokens, PKCE verifier, authorization code, or full OAuth callback query.

## 3. Build/versioning

- Marketing version remains `2.10.0`.
- `CURRENT_PROJECT_VERSION` becomes `42`.

## 4. Tests

Automated tests should cover pure logic that does not require Spotify or camera hardware:

- PKCE challenge generation / state validation where possible;
- Spotify Web API response parsing and best-match selection;
- SpotifyTool argument parsing;
- front/rear camera routing remains intact;
- face diagnostic helper orientation labels/count formatting if extracted as pure helpers.

Full Spotify App Remote and front-camera behavior require a physical iPhone test.

## 5. Manual setup required after code is green

The user must create/configure a Spotify Developer application and provide:

- Bundle ID matching the installed JARVIS app;
- Redirect URI exactly `jarvis-spotify://callback`;
- Spotify Client ID pasted into JARVIS Settings.

No Spotify Client Secret is placed in the iPhone app or GitHub repository.

## 6. Real-device acceptance test

Face:

1. `Jarvis, cadastre meu rosto, sou Cauê, pela câmera frontal.`
2. Export Diagnostics immediately after failure/success.
3. Repeat once with rear camera as control.

Spotify:

1. Connect Spotify once in Settings.
2. `Jarvis, abra o Spotify.`
3. `Toque Sweet Child O' Mine.`
4. `Pause a música.`
5. `Continue.`
6. `Pule essa.`
7. `Volte a música.`
8. `Avance 30 segundos.`
9. Verify `Ok Jarvis` still works while Spotify is playing.

## Non-goals for Build 42

- Playlist editing/library management.
- Recommendation engine.
- Lyrics.
- Downloading/caching Spotify audio.
- Automatic audio-session redesign unless the real-device test proves it is necessary.
- Face-recognition algorithm changes before diagnostics identify the root cause.
