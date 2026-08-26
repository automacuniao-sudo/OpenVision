// JARVIS - JARVISApp.swift
// App entry point with URL scheme handling for Meta AI registration

import SwiftUI
import MWDATCore

@main
struct JARVISApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - State Objects

    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var glassesManager = GlassesManager.shared
    @StateObject private var conversationManager = ConversationManager.shared

    // MARK: - App Storage

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // MARK: - Initialization

    init() {
        // Show timer/alarm notifications even when the app is in the foreground.
        NotificationForegroundPresenter.shared.register()
        SoundService.shared.prepare()
        // Create the location manager on the main thread + warm the cache for contextual notes.
        LocationHelper.shared.prewarm()

        // Move the model store OUT of Caches before anything touches the hub. iOS may purge
        // Caches under storage pressure, which silently deleted downloaded model weights (the app
        // then re-downloaded ~GBs at "connecting…" time). Must run before any HubClient exists.
        GemmaLocalService.bootstrapModelStore()

        // Initialize Meta Wearables SDK
        do {
            try Wearables.configure()
            print("[JARVISApp] Wearables SDK configured")
        } catch {
            print("[JARVISApp] Failed to configure Wearables SDK: \(error)")
        }
        print("[JARVISApp] Initialized")
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    MainTabView()
                        .environmentObject(settingsManager)
                        .environmentObject(glassesManager)
                        .environmentObject(conversationManager)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                handleURL(url)
            }
            .onChange(of: scenePhase) { phase in
                DiagnosticLogger.shared.log(
                    "App",
                    "Scene phase=\(phase) voiceListening=\(VoiceCommandService.shared.isListening) route=\(AudioSessionManager.shared.currentRouteDescription)"
                )

                // A stopped/interrupted voice turn can leave Gemini's resumable WebSocket alive
                // after the app goes to background. Gemini then closes that idle socket every few
                // minutes and the recovery loop reconnects forever, wasting battery/network while
                // the user is not in an active turn. Keep the always-on Apple wake listener, but
                // close an IDLE Gemini connection. The next captured command reconnects on demand.
                if phase == .background,
                   !VoiceCommandService.shared.isWakeRecoverySuppressed,
                   !GeminiLiveService.shared.isProcessing,
                   !GeminiLiveService.shared.isModelSpeaking,
                   GeminiLiveService.shared.connectionState.isUsable {
                    Task { @MainActor in
                        DiagnosticLogger.shared.log("Gemini", "Backgrounded while idle; closing live session")
                        await GeminiLiveService.shared.disconnect()
                    }
                }

                // If iOS returned us to active after an interruption/background transition and the
                // recognizer died, revive wake-word listening. Background audio itself keeps the
                // already-running listener alive; this is a recovery path, not a cold-launch hack.
                if phase == .active,
                   SettingsManager.shared.settings.wakeWordEnabled,
                   VoiceCommandService.shared.authorizationStatus == .authorized,
                   !VoiceCommandService.shared.isWakeRecoverySuppressed,
                   !VoiceCommandService.shared.isListening {
                    try? AudioSessionManager.shared.configureForPhone()
                    try? VoiceCommandService.shared.startListening()
                    DiagnosticLogger.shared.log("Voice", "Recovered wake listener on app activation")
                }
            }
        }
    }

    // MARK: - URL Handling

    /// Handle URL callback from Meta AI app for glasses registration
    private func handleURL(_ url: URL) {
        print("[JARVISApp] Received URL: \(url)")

        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
                print("[JARVISApp] URL handled successfully")
            } catch {
                print("[JARVISApp] Error handling URL: \(error)")
            }
        }
    }
}
