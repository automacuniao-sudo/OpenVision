# Build 42 Face Diagnostics + Spotify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Instrument the front-camera facial-recognition pipeline and add first-class Spotify Premium control through JARVIS native tools.

**Architecture:** Keep the two subsystems isolated. Face work only adds diagnostics to the existing AVFoundation/Vision pipeline. Spotify work adds a dedicated `SpotifyService` and `SpotifyTool`, uses the official Spotify iOS App Remote SDK for playback control, OAuth Authorization Code + PKCE for user authorization, and Spotify Web API search for track-name resolution.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, Vision, Spotify iOS SDK 5.0.1, URLSession, CryptoKit, Security/Keychain, GitHub Actions/XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-04-build42-face-diagnostics-spotify-design.md`

## Global Constraints

- Marketing version remains `2.10.0`; build becomes `42`.
- Do not alter face thresholds, enrollment semantics, or add retries in this build.
- Do not broadly redesign JARVIS audio routing for Spotify before physical-device evidence.
- Never store Spotify Client Secret in the app or repository.
- Never log OAuth tokens, PKCE verifier, auth code, or full callback query.
- Spotify callback is exactly `jarvis-spotify://callback`.
- Spotify SDK is pinned to `5.0.1`.

---

### Task 1: Face diagnostic instrumentation

**Files:**
- Modify: `JARVIS/Services/Vision/PhoneCameraService.swift`
- Modify: `JARVIS/Services/Vision/FaceRecognitionService.swift`
- Create: `JARVIS/Services/Vision/FaceDiagnosticSupport.swift`
- Test: `JARVISTests/FaceDiagnosticSupportTests.swift`

**Interfaces:**
- Produces: `FaceDiagnosticSupport.orientationLabel(_:)`, `FaceDiagnosticSupport.boundingBoxSummary(_:)`.
- Production logging uses `DiagnosticLogger.shared.log("Face", ...)` and `DiagnosticLogger.shared.log("PhoneCamera", ...)`.

- [ ] Step 1: Add tests asserting stable orientation labels and bounding-box formatting.
- [ ] Step 2: Run CI and confirm tests fail because `FaceDiagnosticSupport` is absent.
- [ ] Step 3: Add the helper and diagnostic logs for camera capture, normalized image, face-detection count/timing, crop size, feature-print timing/count, total pipeline timing, and diagnostic-only four-orientation probe when the normal pass finds zero faces.
- [ ] Step 4: Run CI and confirm tests/build pass without changing recognition behavior.
- [ ] Step 5: Commit face diagnostics independently.

### Task 2: Spotify pure logic and configuration

**Files:**
- Create: `JARVIS/Services/Spotify/SpotifyAuthSupport.swift`
- Create: `JARVIS/Services/Spotify/SpotifyModels.swift`
- Test: `JARVISTests/SpotifyAuthSupportTests.swift`
- Test: `JARVISTests/SpotifyModelsTests.swift`
- Modify: `project.yml`
- Modify: `JARVIS/Resources/Info.plist`

**Interfaces:**
- Produces: PKCE verifier/challenge helpers, OAuth state validation, `SpotifyTrackSearchResponse`, `SpotifyTrack`.
- Adds Swift package `spotify-ios-sdk` exact version `5.0.1`, product `SpotifyiOS`.
- Registers `jarvis-spotify` callback scheme and `spotify` query scheme.

- [ ] Step 1: Add tests for PKCE challenge determinism/state validation and Spotify search-response parsing.
- [ ] Step 2: Run CI and confirm tests fail before production helpers exist.
- [ ] Step 3: Implement minimal pure helpers/models and package/plist configuration.
- [ ] Step 4: Run CI and confirm tests/package resolution pass.
- [ ] Step 5: Commit Spotify foundation independently.

### Task 3: Spotify service, settings, and native tool

**Files:**
- Create: `JARVIS/Services/Spotify/SpotifyTokenStore.swift`
- Create: `JARVIS/Services/Spotify/SpotifyService.swift`
- Create: `JARVIS/Services/NativeTools/SpotifyTool.swift`
- Create: `JARVIS/Views/Settings/SpotifySettingsView.swift`
- Modify: `JARVIS/Services/NativeTools/NativeTool.swift`
- Modify: `JARVIS/App/JARVISApp.swift`
- Modify: `JARVIS/Models/AppSettings.swift`
- Modify: `JARVIS/Managers/SettingsManager.swift`
- Modify: `JARVIS/Views/Settings/SettingsView.swift`
- Test: `JARVISTests/SpotifyToolSupportTests.swift`

**Interfaces:**
- `SpotifyService.shared.authorize()`, `handleCallback(_:)`, `openSpotify()`, `play(query:)`, `pause()`, `resume()`, `next()`, `previous()`, `seek(seconds:)`, `setShuffle(_:)`, `status()`.
- Native tool name: `spotify`; actions: `open`, `connect`, `play`, `pause`, `resume`, `next`, `previous`, `seek`, `shuffle`, `status`.
- Non-secret `spotifyClientID` persists in normal settings; token material persists only in Keychain.

- [ ] Step 1: Add pure argument-validation tests for Spotify tool actions.
- [ ] Step 2: Run CI and confirm tests fail before helper/tool exists.
- [ ] Step 3: Implement Keychain token store, OAuth PKCE flow, token refresh, Web API search, App Remote commands, Settings UI, URL callback dispatch, and native-tool registration.
- [ ] Step 4: Run full CI and resolve only Build 42 regressions.
- [ ] Step 5: Commit Spotify integration independently.

### Task 4: Version and final verification

**Files:**
- Modify: `project.yml`
- Modify: `CHANGELOG.md`

- [ ] Step 1: Set `CURRENT_PROJECT_VERSION` to `42` and document Build 42.
- [ ] Step 2: Run full PR CI and verify portable tests plus device build-for-testing are green.
- [ ] Step 3: Review diff for secrets and unrelated audio/face behavior changes.
- [ ] Step 4: Keep PR unmerged until explicit user approval after review.
