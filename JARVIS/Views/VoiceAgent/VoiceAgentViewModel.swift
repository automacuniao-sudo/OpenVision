// OpenVision - VoiceAgentViewModel.swift
// MVVM: all voice-session orchestration for the main screen lives here — session lifecycle,
// command routing, live video, face intents, photo capture, TTS streaming, and history.
// VoiceAgentView renders this state and forwards user interactions; it holds no logic.
//
// The services are app-wide singletons; this ViewModel is their single orchestrator. Service
// callbacks capture self weakly — the services outlive any owner, so strong captures would pin
// the ViewModel forever.

import SwiftUI
import Speech

@MainActor
final class VoiceAgentViewModel: ObservableObject {

    // MARK: - Dependencies

    let settingsManager = SettingsManager.shared
    let glassesManager = GlassesManager.shared
    let voiceCommandService = VoiceCommandService.shared
    let geminiVision = GeminiVisionService.shared
    let geminiLive = GeminiLiveService.shared
    let openAIRealtime = OpenAIRealtimeService.shared
    let ttsService = TTSService.shared
    let geminiStreamingTTS = GeminiStreamingTTSService.shared
    let soundService = SoundService.shared
    let audioCapture = AudioCaptureService()
    let audioPlayback = AudioPlaybackService()
    let sessionRecorder = SessionRecorder.shared

    // MARK: - Published UI state

    @Published var isSessionActive = false
    @Published var agentState: AgentState = .idle
    @Published var userTranscript = ""
    @Published var aiTranscript = ""
    @Published var currentToolName: String?
    @Published var errorMessage: String?
    /// Live Video Mode - uses Gemini Live or OpenAI Realtime for real-time audio + video
    @Published var isLiveVideoMode = false
    /// True when voice recognition is ready (audio engine running)
    @Published var isVoiceReady = false
    /// True while a POV demo recording (glasses video + mic audio) is in progress.
    @Published var isRecording = false
    /// Transient status shown after a recording finishes ("Saved to Photos" / a failure). Auto-clears.
    @Published var recordingStatus: String?

    // MARK: - Internal state

    // De-dup: the last command we processed and when (drops duplicate recognizer emissions).
    private var lastProcessedCommand = ""
    private var lastProcessedAt = Date.distantPast
    private var hasRequestedSpeechAuth = false

    /// The live-video backend currently driving audio/video (Gemini or OpenAI Realtime).
    /// Set when live video mode starts; used by stop/callbacks so both backends route correctly.
    private var activeLiveService: (any LiveVideoService)?

    /// Sentence-streaming TTS: how many characters of the streamed reply have already been
    /// handed to the active speech engine (Apple, Kokoro or Gemini Streaming TTS).
    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false

    private var isDirectGeminiVoiceMode = false
    private var directGeminiAwaitingNewInput = true
    private var directGeminiTimeoutTask: Task<Void, Never>?
    private var directGeminiResponseWatchdogTask: Task<Void, Never>?

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
    /// system utterances ("Live video mode active", error prompts) out of the History tab.
    private var historyAwaitingReply = false
    /// History (live modes): last streamed AI turn already recorded, to dedupe turn-complete events.
    private var historyLastLiveReply = ""

    /// Frame counter for logging
    private var videoFrameCount: Int = 0

    // MARK: - Agent State

    enum AgentState: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case toolRunning
        case liveVideo  // Live video mode - Gemini handles audio + video

        var displayText: String {
            switch self {
            case .idle: return "Tap to start"
            case .connecting: return "Connecting..."
            case .listening: return "Listening..."
            case .thinking: return "Thinking..."
            case .speaking: return "Speaking..."
            case .toolRunning: return "Running tool..."
            case .liveVideo: return "Live Video"
            }
        }

        var accentColor: Color {
            switch self {
            case .idle: return .gray
            case .connecting: return .orange
            case .listening: return .blue
            case .thinking: return .purple
            case .speaking: return .green
            case .toolRunning: return .orange
            case .liveVideo: return .red  // Red for live video recording indicator
            }
        }
    }

    // MARK: - View lifecycle

    func onAppear() {
        setupVoiceCommandService()
        setupGlassesCallbacks()
        preloadLocalModelIfNeeded()
        if settingsManager.settings.voiceOwnerLockEnabled {
            Task { await SpeakerVerificationService.shared.warmUp() }
        }
        // Resume wake-word listening when returning to this screen. onDisappear stops it
        // (e.g. when navigating to Settings), and the one-time .task doesn't re-run on return —
        // so without this, the wake word stayed dead until you tapped the mic button.
        if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    func onDisappear() {
        // Deliberately keep the wake-word audio runtime alive when the user leaves the Voice tab
        // or backgrounds the app. UIBackgroundModes=audio is already enabled; tying recognition
        // to this SwiftUI view made JARVIS stop being hands-free as soon as the tab disappeared.
        DiagnosticLogger.shared.log("Voice", "Voice view disappeared; keeping wake listener alive")
    }

    // MARK: - Observed state changes (forwarded from the view's onChange hooks)

    func ttsSpeakingChanged(_ isSpeaking: Bool) {
        if isSpeaking {
            agentState = .speaking
            // Pause barge-in detection while TTS is playing
            // (prevents microphone picking up TTS and triggering interruption)
            voiceCommandService.isBargeInPaused = true
        } else {
            MetricsCollector.shared.markSpokeDone()
            // Resume barge-in detection
            voiceCommandService.isBargeInPaused = false

            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    // Kokoro drives the same speaking-state flow as Apple TTS: keep the recognizer running
    // (in .processing) with barge-in paused so it stays in the conversation loop, then enter
    // conversation mode when playback finishes. (Don't stopListening — that trips the .idle
    // session-teardown observer and ends the conversation after every reply.)
    func kokoroSpeakingChanged(_ speaking: Bool) {
        if speaking {
            agentState = .speaking
            voiceCommandService.isBargeInPaused = true
        } else {
            MetricsCollector.shared.markSpokeDone()
            voiceCommandService.isBargeInPaused = false
            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    /// Control thinking sound based on agent state.
    func agentStateChanged(_ newState: AgentState) {
        if newState == .thinking || newState == .toolRunning {
            soundService.startThinkingSound()
        } else {
            soundService.stopThinkingSound()
        }
    }

    func voiceStateChanged(_ newState: VoiceCommandService.ListeningState) {
        print("[VoiceAgent] VoiceCommandService state changed to: \(newState)")
        switch newState {
        case .idle:
            // In live video mode, a silence timeout must NOT end the mode — the user expects
            // to keep asking questions (camera stays on) until they say "stop video". Re-arm
            // conversation mode so the next question is heard without a fresh wake word.
            if isLiveVideoMode {
                print("[VoiceAgent] Idle during live video — re-arming conversation mode")
                voiceCommandService.enterConversationMode()
                agentState = .liveVideo
                return
            }
            // Direct Gemini deliberately stops Apple Speech when the realtime PCM stream takes
            // ownership of the microphone. That stop emits `.idle`; it is a microphone handoff,
            // NOT the end of the conversation. Build 33 still let the legacy idle observer race
            // with startDirectGeminiVoiceMode(), which disconnected Gemini milliseconds after a
            // successful wake connection. Suppression is set before stopListening(), so it is the
            // authoritative handoff guard even before isDirectGeminiVoiceMode flips true.
            if voiceCommandService.isWakeRecoverySuppressed || isDirectGeminiVoiceMode {
                DiagnosticLogger.shared.log("Voice", "Ignored recognizer idle during direct Gemini mic handoff")
                return
            }

            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking/.toolRunning command processing, .speaking a reply) is a transient from
            // our own stop/restart — e.g. the camera capture restarts the recognizer mid-command
            // — and must NOT tear the session down.
            if isSessionActive && agentState == .listening {
                print("[VoiceAgent] Voice service idle, stopping session")
                isSessionActive = false
                agentState = .idle
                // Disconnect AI backend
                Task {
                    switch settingsManager.settings.aiBackend {
                    case .openClaw:
                        await OpenClawService.shared.disconnect()
                    case .geminiLive:
                        await GeminiLiveService.shared.disconnect()
                    case .openAI:
                        break   // stateless HTTP — nothing to disconnect
                    case .appleFoundation:
                        break   // OS-managed — nothing to disconnect
                    case .localGemma:
                        // Keep the on-device model LOADED so the next "Ok Vision" is instant.
                        // Unloading + reloading the ~3.6GB model per conversation was the cause
                        // of the "connecting…" lag and hangs. It stays resident until the app
                        // backgrounds or the user switches backend.
                        break
                    }
                }
            }
        case .listening, .conversationMode:
            // Keep the live indicator up in live video mode (don't clobber it back to
            // plain .listening, which would let the next idle tear the session down).
            if isLiveVideoMode {
                agentState = .liveVideo
            } else if ttsService.isSpeaking || KokoroTTSService.shared.isSpeaking {
                // The recognizer restarts (→ conversation mode) mid-reply for barge-in; don't
                // let that flip the UI to "Listening" while the assistant is still speaking.
                agentState = .speaking
            } else if isSessionActive {
                agentState = .listening
            }
        case .processing:
            agentState = .thinking
        }
    }

    // MARK: - Session lifecycle

    func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        // Check configuration
        guard settingsManager.settings.isCurrentBackendConfigured else {
            errorMessage = "Please configure \(settingsManager.settings.aiBackend.displayName) in Settings"
            return
        }

        isSessionActive = true
        agentState = .connecting

        // Model memory follows the History conversation window (5-min inactivity), NOT the wake
        // session — every "Ok Vision" starts a new session, so clearing here made "what were we
        // just talking about?" fail seconds after the previous answer. Only reset memory when
        // enough time has passed that History would start a new conversation anyway.
        if !ConversationManager.shared.isCurrentConversationFresh {
            ConversationContext.shared.clear()
            AppleFoundationService.shared.resetContext()
        }

        // Configure audio routing for glasses if registered
        configureAudioForGlasses()

        // Connect to AI backend
        Task {
            do {
                switch settingsManager.settings.aiBackend {
                case .openClaw:
                    try await OpenClawService.shared.connect()
                    // Note: Streaming NOT auto-started in OpenClaw mode
                    // User says "start video stream" → startLiveVideoMode()
                    // User says "take a photo" → captureAndSendPhoto() starts streaming on-demand

                case .openAI:
                    try await OpenAIService.shared.connect()
                    // Stateless HTTP — photos are captured on-demand like OpenClaw.

                case .appleFoundation:
                    try await AppleFoundationService.shared.connect()
                    // On-device Apple model — text only; camera commands guide to a cloud backend.

                case .geminiLive:
                    try await GeminiLiveService.shared.connect()
                    // Start glasses streaming for Gemini Live mode
                    if glassesManager.isRegistered && !glassesManager.isStreaming {
                        print("[VoiceAgent] Starting glasses stream for Gemini Live...")
                        await glassesManager.startStreaming()
                    }

                case .localGemma:
                    // On-device Gemma: load the model (must be downloaded first).
                    // Text-only in Phase 1 — no glasses streaming needed.
                    try await GemmaLocalService.shared.connect(
                        modelId: settingsManager.settings.localGemmaModelId
                    )
                }

                agentState = .listening
                userTranscript = ""
                aiTranscript = ""

                if settingsManager.settings.aiBackend == .geminiLive {
                    if settingsManager.settings.voiceOwnerLockEnabled {
                        // Security mode verifies each utterance locally before it reaches Gemini.
                        // Raw realtime PCM cannot be speaker-gated without buffering, so Owner Lock
                        // deliberately uses Apple STT -> verified text turns.
                        voiceCommandService.persistentConversationMode = true
                        if !voiceCommandService.isListening {
                            try? voiceCommandService.startListening()
                        }
                        voiceCommandService.enterConversationMode()
                        DiagnosticLogger.shared.log("VoiceAuth", "Gemini secure input mode active (verified STT turns)")
                    } else {
                        // Lowest-latency normal mode keeps native full-duplex Gemini audio.
                        voiceCommandService.persistentConversationMode = false
                        try startDirectGeminiVoiceMode()
                    }
                } else {
                    // Text backends still use Apple STT, but the conversation itself is persistent:
                    // silence no longer tears the session down and forces another wake phrase.
                    if voiceCommandService.authorizationStatus == .authorized {
                        voiceCommandService.persistentConversationMode = true
                        if !voiceCommandService.isListening {
                            try? voiceCommandService.startListening()
                        }
                        voiceCommandService.enterConversationMode()
                    } else {
                        reportVoiceError(
                            "Speech recognition not authorized",
                            spoken: "O reconhecimento de voz não está autorizado."
                        )
                    }
                }

            } catch {
                reportVoiceError(
                    "Failed to connect: \(error.localizedDescription)",
                    spoken: "Não consegui conectar ao serviço de inteligência agora. Verifique a conexão e tente novamente."
                )
                isSessionActive = false
                agentState = .idle
            }
        }
    }

    /// Resume listening after a spoken response ends — camera and text commands end identically:
    /// the persistent audio engine keeps running through a capture (never torn down — a rebuild
    /// would force a fresh Bluetooth HFP negotiation the glasses can't service right after
    /// streaming, leaving the mic deaf). Conversation mode's silence timeout then returns to idle.
    private func resumeListeningAfterSpeaking() {
        if isDirectGeminiVoiceMode {
            armDirectGeminiConversationTimeout()
        } else {
            voiceCommandService.enterConversationMode()
        }
    }

    private func startDirectGeminiVoiceMode() throws {
        directGeminiTimeoutTask?.cancel()
        directGeminiAwaitingNewInput = true

        // Direct Gemini streams PCM continuously. Mark microphone ownership BEFORE stopping the
        // wake recognizer so scene-activation recovery cannot race in and start Apple Speech again.
        voiceCommandService.isWakeRecoverySuppressed = true
        if voiceCommandService.isListening {
            voiceCommandService.stopListening()
        }

        audioCapture.onAudioCaptured = { [weak self] data in
            SpeakerVerificationService.shared.feedPCM16(data)
            self?.geminiLive.sendAudio(data: data)
        }

        do {
            try audioCapture.startCapture()
            isDirectGeminiVoiceMode = true
            DiagnosticLogger.shared.log("Gemini", "Direct microphone PCM streaming active")
            armDirectGeminiConversationTimeout()
        } catch {
            audioCapture.onAudioCaptured = nil
            isDirectGeminiVoiceMode = false
            voiceCommandService.isWakeRecoverySuppressed = false
            if settingsManager.settings.wakeWordEnabled,
               voiceCommandService.authorizationStatus == .authorized,
               !voiceCommandService.isListening {
                try? voiceCommandService.startListening()
            }
            throw error
        }
    }

    private func stopDirectGeminiVoiceMode() {
        directGeminiTimeoutTask?.cancel()
        directGeminiTimeoutTask = nil
        directGeminiResponseWatchdogTask?.cancel()
        directGeminiResponseWatchdogTask = nil
        guard isDirectGeminiVoiceMode || audioCapture.isCapturing else { return }
        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil
        isDirectGeminiVoiceMode = false
        voiceCommandService.isWakeRecoverySuppressed = false
        directGeminiAwaitingNewInput = true
        DiagnosticLogger.shared.log("Gemini", "Direct microphone PCM streaming stopped")
    }

    private func armDirectGeminiConversationTimeout() {
        // Conversation Runtime v2 intentionally has no per-turn idle shutdown. ChatGPT-style voice
        // is a call/session: after the initial wake word the mic remains owned by the realtime
        // session until the user explicitly stops it, the UI stops it, or recovery is exhausted.
        directGeminiTimeoutTask?.cancel()
        directGeminiTimeoutTask = nil
        guard isDirectGeminiVoiceMode, isSessionActive else { return }
        DiagnosticLogger.shared.log("Voice", "Direct Gemini persistent conversation active (idle auto-end disabled)")
    }

    private func armDirectGeminiResponseWatchdog() {
        directGeminiResponseWatchdogTask?.cancel()
        directGeminiResponseWatchdogTask = nil
        guard isDirectGeminiVoiceMode, isSessionActive else { return }

        directGeminiResponseWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }
            guard let self, self.isDirectGeminiVoiceMode, self.isSessionActive else { return }
            guard !self.geminiLive.isModelSpeaking,
                  !self.geminiLive.isToolRunning else { return }

            let retryText = self.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticLogger.shared.log("Voice", "Gemini silent-turn watchdog fired; recovering live session")
            do {
                try await self.geminiLive.recoverLiveSession(reason: "15s without audio/tool progress")
                // Session resumption preserves context, but the turn that froze may not be replayed.
                // Re-submit its transcript once as text so the user is not left in dead silence.
                if !retryText.isEmpty {
                    try await self.geminiLive.sendText(retryText)
                    DiagnosticLogger.shared.log("Voice", "Silent turn replayed after Gemini recovery")
                }
            } catch {
                self.recoverDirectConversationToWake(reason: "Gemini recovery failed: \(error.localizedDescription)")
            }
        }
    }

    private func recoverDirectConversationToWake(reason: String) {
        guard isDirectGeminiVoiceMode || voiceCommandService.isWakeRecoverySuppressed else { return }
        DiagnosticLogger.shared.log("Voice", "Conversation runtime recovering to wake listener: \(reason)")
        stopDirectGeminiVoiceMode()
        voiceCommandService.persistentConversationMode = false
        isSessionActive = false
        agentState = .idle
        currentToolName = nil

        if settingsManager.settings.wakeWordEnabled,
           voiceCommandService.authorizationStatus == .authorized,
           !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    private var shouldUseGeminiStreamingVoiceForOpenClaw: Bool {
        settingsManager.settings.aiBackend == .openClaw
            && !settingsManager.settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usingKokoroTTS: Bool {
        settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady
    }

    private var canStreamSpeech: Bool {
        shouldUseGeminiStreamingVoiceForOpenClaw || usingKokoroTTS || usingAppleTTS
    }

    private var activeTTSEngineTag: String {
        if shouldUseGeminiStreamingVoiceForOpenClaw { return "gemini-streaming" }
        if usingKokoroTTS { return "kokoro" }
        return "apple"
    }

    private func beginActiveStreamingTTS() {
        MetricsCollector.shared.markTTSRequested()
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.beginStreaming()
        } else if usingKokoroTTS {
            KokoroTTSService.shared.beginStreaming()
        } else {
            ttsService.beginStreaming()
        }
    }

    private func speakActiveStreamingChunk(_ text: String) {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.speakChunk(text)
        } else if usingKokoroTTS {
            KokoroTTSService.shared.speakChunk(text, voice: settingsManager.settings.kokoroVoice)
        } else {
            ttsService.speakChunk(text)
        }
    }

    private func endActiveStreamingTTS() {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.endStreaming()
        } else if usingKokoroTTS {
            KokoroTTSService.shared.endStreaming()
        } else {
            ttsService.endStreaming()
        }
    }

    private func stopActiveStreamingTTS() {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.stop()
        } else if usingKokoroTTS {
            KokoroTTSService.shared.stop()
        } else {
            ttsService.stop()
        }
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
    /// and they're the connected audio device, otherwise the phone's built-in mic + loud speaker.
    /// Attempting glasses is what makes iOS expose the HFP mic — so we try it directly rather than
    /// pre-checking availability (which can't see HFP until it's allowed). Returns true on glasses.
    @discardableResult
    private func applyPreferredAudioRoute() -> Bool {
        // Never pick the glasses HFP mic while the camera is streaming: video saturates the
        // Bluetooth link, so the SCO audio channel can't be serviced. configureForGlasses() can
        // still "succeed" in that state, but the mic is deaf — commands are never transcribed
        // (seen when recording starts the stream before a wake-word session). Phone mic instead.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,
           (try? AudioSessionManager.shared.configureForGlasses()) == true {
            return true
        }
        // Glasses mic off, glasses not connected as audio, or no HFP input available → phone.
        // Loud speaker so spoken replies are audible (not the quiet earpiece).
        print("[VoiceAgent] Using iPhone mic + speaker (glasses mic off or unavailable)")
        try? AudioSessionManager.shared.configureForPhone()
        return false
    }

    private func configureAudioForGlasses() {
        // If we're already on the glasses' Bluetooth (HFP) route and still listening, do NOT tear
        // the audio session down and re-activate it. That re-activation renegotiates the HFP SCO
        // link, which the glasses render as a "Bluetooth connecting/closing" blip — heard on every
        // wake after the first (the route stays on HFP between sessions, so the re-config is pure
        // churn). Skipping it keeps SCO stable, so the wake chime plays cleanly each time.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,   // HFP is deaf while the camera streams — reconfigure to phone
           AudioSessionManager.shared.isBluetoothHFPActive, voiceCommandService.isListening {
            return
        }

        // Phone-only wake path: if the persistent listener is already using the built-in mic/output,
        // do NOT stop/restart the audio engine at the exact moment the acknowledgement chime starts.
        // Just re-assert speakerphone routing. This preserves the chime and avoids the low-volume
        // receiver renegotiation observed after saying the wake phrase.
        if voiceCommandService.isListening,
           AudioSessionManager.shared.isUsingBuiltInMic,
           AudioSessionManager.shared.isUsingBuiltInOutput {
            AudioSessionManager.shared.enforcePhoneSpeakerRoute()
            DiagnosticLogger.shared.log("Audio", "Wake session reused existing phone audio route")
            return
        }

        let wasListening = voiceCommandService.isListening
        if wasListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()
        if wasListening {
            try? voiceCommandService.startListening()
        }
    }

    func stopSession() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        voiceCommandService.persistentConversationMode = false
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }

        // If in live video mode, stop it first
        if isLiveVideoMode {
            Task {
                await stopLiveVideoMode()
            }
        }

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw:
                await OpenClawService.shared.disconnect()
            case .geminiLive:
                await GeminiLiveService.shared.disconnect()
            case .openAI:
                break   // stateless HTTP — nothing to disconnect
            case .appleFoundation:
                break   // OS-managed — nothing to disconnect
            case .localGemma:
                // Keep the on-device model loaded — see note in the .idle handler. Reloading it
                // per conversation was what made "Ok Vision" slow/flaky.
                break
            }

            // Stop glasses streaming (turns off LED)
            if glassesManager.isStreaming {
                print("[VoiceAgent] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()
        geminiStreamingTTS.stop()
        KokoroTTSService.shared.stop()

        // Set session inactive FIRST to prevent callbacks from processing
        isSessionActive = false
        agentState = .idle

        // Handle voice command service based on wake word setting
        if settingsManager.settings.wakeWordEnabled {
            if wasDirectGeminiVoice {
                if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
                    startWakeWordListening()
                }
            } else {
                voiceCommandService.exitConversationMode()
            }
        } else {
            // Wake word disabled - stop listening entirely to prevent
            // processing speech after session ends
            voiceCommandService.stopListening()
        }
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isLiveVideoMode = false
    }

    /// Full stop for "Ok Vision stop": silence all output, cancel any in-flight generation, and go
    /// quiet back to wake-word listening. The recognizer buffer is already reset by
    /// VoiceCommandService (so the stale transcript can't re-fire); here we just halt + end the turn.
    private func performFullStop() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        let stayingInLiveVideo = isLiveVideoMode

        MetricsCollector.shared.markInterrupted()
        MetricsCollector.shared.markSpokeDone()

        // A bare "stop" silences the current answer. Only "stop video" tears down live video.
        if !stayingInLiveVideo {
            voiceCommandService.persistentConversationMode = false
        }
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
        ttsService.stop()
        geminiStreamingTTS.stop()
        KokoroTTSService.shared.stop()
        audioPlayback.stop()
        ttsStreaming = false

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw: await OpenClawService.shared.interrupt()
            case .geminiLive: await GeminiLiveService.shared.interrupt()
            case .openAI: break   // single request/response — nothing to interrupt
            case .appleFoundation: AppleFoundationService.shared.interrupt()
            case .localGemma: GemmaLocalService.shared.interrupt()
            }
        }

        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil

        if stayingInLiveVideo {
            DiagnosticLogger.shared.log("Voice", "Stop silenced current reply; staying in live video")
            voiceCommandService.persistentConversationMode = true
            voiceCommandService.enterConversationMode()
            agentState = .liveVideo
            return
        }

        // Go quiet: end the turn, return to wake-word idle. Say "Ok Jarvis" to start again.
        isSessionActive = false
        agentState = .idle

        if wasDirectGeminiVoice,
           settingsManager.settings.wakeWordEnabled,
           voiceCommandService.authorizationStatus == .authorized,
           !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    // MARK: - Voice Command Setup

    /// Warm up the on-device model in the background so the FIRST "Ok Vision" is instant
    /// (no multi-second load on wake). Only when Local Gemma is the selected, downloaded backend.
    private func preloadLocalModelIfNeeded() {
        guard settingsManager.settings.aiBackend == .localGemma,
              settingsManager.settings.localGemmaModelReady else { return }
        Task {
            do {
                try await GemmaLocalService.shared.connect(modelId: settingsManager.settings.localGemmaModelId)
                print("[VoiceAgent] Local model preloaded — wake word will be instant")
            } catch {
                print("[VoiceAgent] Local model preload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Request speech recognition authorization
    func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            print("[VoiceAgent] Speech recognition authorized")
            startWakeWordListening()
        } else {
            print("[VoiceAgent] Speech recognition not authorized")
            isVoiceReady = false
            reportVoiceError(
                "Speech recognition not authorized. Please enable in Settings.",
                spoken: "Não consegui acessar o reconhecimento de voz. Verifique a permissão do microfone e da fala nos Ajustes."
            )
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        print("[VoiceAgent] Setting up voice command callbacks")

        // Allow wake word to interrupt TTS (for "ok vision stop")
        voiceCommandService.shouldAllowInterrupt = { [weak self] in
            guard let self else { return false }
            return self.ttsService.isSpeaking
                || self.geminiStreamingTTS.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || GeminiLiveService.shared.isProcessing
                || OpenClawService.shared.isProcessing
                || OpenClawService.shared.isToolRunning
                || self.agentState == .thinking
                || self.agentState == .toolRunning
                || self.audioPlayback.isPlaying
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Wake word detected!")
            HapticFeedback.medium()
            self.soundService.playWakeWordSound()

            // If any reply/generation path owns the floor, a wake is an interruption.
            let interrupting = self.ttsService.isSpeaking
                || self.geminiStreamingTTS.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || GeminiLiveService.shared.isProcessing
                || OpenClawService.shared.isProcessing
                || OpenClawService.shared.isToolRunning
                || self.audioPlayback.isPlaying
                || self.agentState == .thinking
                || self.agentState == .toolRunning
            if interrupting {
                print("[VoiceAgent] Stopping active reply due to wake word interrupt")
                MetricsCollector.shared.markInterrupted()
                MetricsCollector.shared.markSpokeDone()
                self.ttsService.stop()
                self.geminiStreamingTTS.stop()
                self.ttsStreaming = false
                KokoroTTSService.shared.stop()
                self.audioPlayback.stop()
                // Cancel any in-flight on-device generation too — otherwise its next streamed
                // token would immediately restart speech we just stopped.
                GemmaLocalService.shared.interrupt()
                self.agentState = .listening
            }

            // Auto-start session if not already active (use Task to avoid blocking)
            Task { @MainActor in
                if !self.isSessionActive && self.settingsManager.settings.isCurrentBackendConfigured {
                    print("[VoiceAgent] Starting session from wake word...")
                    self.startSession()
                }
            }
        }

        // "Ok Vision stop" during a reply → full stop, go quiet (the recognizer is already reset
        // to wake-word idle by VoiceCommandService; here we just halt output + end the turn).
        voiceCommandService.onStopCommand = { [weak self] in
            print("[VoiceAgent] Full stop requested")
            self?.performFullStop()
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { [weak self] (command: String) in
            guard let self else { return }
            print("[VoiceAgent] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                print("[VoiceAgent] Ignoring command - session not active")
                return
            }

            self.userTranscript = command
            let backend = self.settingsManager.settings.aiBackend
            MetricsCollector.shared.markCommit(
                backend: backend.rawValue,
                model: backend == .localGemma ? self.settingsManager.settings.localGemmaModelId : nil,
                ttsEngine: self.activeTTSEngineTag
            )
            // Gemini Live output transcription is streamed in small fragments. Reset the reply
            // accumulator at the start of EVERY captured command so History stores one complete
            // assistant message for this turn rather than the final fragment only.
            self.aiTranscript = ""
            self.historyLastLiveReply = ""

            // History: every captured command is a user message (Meta AI records all glasses
            // prompts to its History tab; same idea, on-device).
            ConversationManager.shared.addUserMessage(command)
            self.historyAwaitingReply = true

            // Send command to AI backend
            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Barge-in detected")
            MetricsCollector.shared.markInterrupted()
            MetricsCollector.shared.markSpokeDone()

            // Stop every local output path immediately. Gemini normal voice uses its own
            // fallback player, which is stopped by GeminiLiveService.interrupt() below.
            self.ttsService.stop()
            self.geminiStreamingTTS.stop()
            KokoroTTSService.shared.stop()
            self.audioPlayback.stop()

            // Stop current AI response
            Task {
                switch self.settingsManager.settings.aiBackend {
                case .openClaw:
                    await OpenClawService.shared.interrupt()
                case .geminiLive:
                    await GeminiLiveService.shared.interrupt()
                case .openAI:
                    break   // single request/response — nothing to interrupt
                case .appleFoundation:
                    AppleFoundationService.shared.interrupt()
                case .localGemma:
                    GemmaLocalService.shared.interrupt()
                }
            }
        }

        // Idle pulse inside an already-open conversation. The service itself re-arms the
        // recognizer when persistentConversationMode is enabled; never tear down the backend here.
        voiceCommandService.onConversationTimeout = { [weak self] in
            guard let self else { return }
            if self.isLiveVideoMode {
                print("[VoiceAgent] Conversation idle pulse during live video — staying live")
                return
            }
            guard self.isSessionActive, self.voiceCommandService.persistentConversationMode else { return }
            self.agentState = .listening
            DiagnosticLogger.shared.log("Voice", "Conversation idle pulse; session remains active")
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        print("[VoiceAgent] Voice command callbacks setup complete")
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // Shared reply/state wiring — every AIBackend reports through the same two callbacks,
        // so wire them once for all. (Gemini Live is a streaming session and delivers replies
        // via its own transcription callbacks below; its protocol callbacks are inert.)
        for backend in AIBackendRegistry.all {
            backend.onAgentMessage = { [weak self] (message: String) in
                guard let self else { return }
                // In local live video mode replies must flow even if the session timer lapsed
                // while the user was silently looking around.
                guard self.isSessionActive || self.isLiveVideoMode else { return }
                self.aiTranscript = message
                MetricsCollector.shared.markFirstToken()
                MetricsCollector.shared.markGenerationDone()
                if self.ttsStreaming {
                    // A streamed utterance is open (local model + Apple TTS pipelining):
                    // flush the unspoken tail and close the session.
                    self.feedStreamingSpeech(message, isFinal: true)
                } else {
                    self.speakResponse(message)
                }
            }
            backend.onProcessingChanged = { [weak self] (isProcessing: Bool) in
                guard let self else { return }
                if isProcessing {
                    self.agentState = .thinking
                    // New reply: reset the sentence-streaming cursor for a clean start.
                    self.ttsStreaming = false
                    self.ttsStreamSpokenChars = 0
                } else {
                    MetricsCollector.shared.markGenerationDone()
                    // Generation ended (always fires via defer, even when interrupted/superseded).
                    // If a streamed utterance is still open, onAgentMessage never fired to close it —
                    // close it here so streamingActive/isSpeaking don't stick true and freeze the
                    // wake-word listener (queued sentences still drain and reset isSpeaking).
                    if self.ttsStreaming {
                        self.endActiveStreamingTTS()
                        self.ttsStreaming = false
                    }
                    if self.agentState == .thinking
                        && !self.ttsService.isSpeaking
                        && !KokoroTTSService.shared.isSpeaking
                        && !self.geminiStreamingTTS.isSpeaking
                        && !self.audioPlayback.isPlaying {
                        // Return to the live video indicator, not plain listening, while in live mode.
                        self.agentState = self.isLiveVideoMode ? .liveVideo
                            : (self.isSessionActive ? .listening : .idle)
                    }
                }
            }
        }

        // Local Gemma extra: token streaming (pipelines Apple TTS behind generation).
        GemmaLocalService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self else { return }
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            // Show tokens as they stream so it doesn't look stuck on "thinking".
            self.aiTranscript = partial
            MetricsCollector.shared.markFirstToken()
            // Start speaking completed sentences as they arrive. Apple TTS does this without GPU
            // contention; Kokoro now uses a single FIFO drainer so chunks remain ordered.
            if self.canStreamSpeech { self.feedStreamingSpeech(partial, isFinal: false) }
        }

        // OpenClaw partial text is a cumulative snapshot. Speak completed sentences while
        // generation is still running instead of waiting for the final response.
        OpenClawService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self, self.isSessionActive else { return }
            self.aiTranscript = partial
            MetricsCollector.shared.markFirstToken()
            self.feedStreamingSpeech(partial, isFinal: false)
        }

        geminiStreamingTTS.onSpeechStarted = { [weak self] in
            guard let self else { return }
            self.agentState = .speaking
            self.voiceCommandService.isBargeInPaused = true
        }
        geminiStreamingTTS.onSpeechEnded = { [weak self] in
            guard let self else { return }
            MetricsCollector.shared.markSpokeDone()
            self.voiceCommandService.isBargeInPaused = false
            if self.isSessionActive {
                self.agentState = .listening
                self.resumeListeningAfterSpeaking()
            } else {
                self.agentState = .idle
            }
        }

        // OpenClaw extras: tool status + device-side tool calls.
        OpenClawService.shared.onToolStatusChanged = { [weak self] (toolName: String?, isRunning: Bool) in
            guard let self else { return }
            print("[VoiceAgent] Tool status: \(toolName ?? "none"), running: \(isRunning)")
            self.currentToolName = toolName
            if isRunning {
                self.agentState = .toolRunning
            }
        }

        // Handle tool calls (e.g., take_photo)
        OpenClawService.shared.onToolCall = { [weak self] (toolName: String, args: [String: Any], completion: @escaping (String) -> Void) in
            guard let self else { return }
            print("[VoiceAgent] Tool call: \(toolName) with args: \(args)")

            switch toolName {
            case "take_photo", "capture_photo", "take_picture":
                // Capture photo from glasses
                Task { @MainActor in
                    await self.handleTakePhotoTool(completion: completion)
                }

            case "describe_scene", "what_do_you_see", "look":
                // Query Gemini Vision for scene description
                Task { @MainActor in
                    await self.handleDescribeSceneTool(args: args, completion: completion)
                }

            default:
                print("[VoiceAgent] Unknown tool: \(toolName)")
                completion("Tool '\(toolName)' is not available on this device.")
            }
        }

        // Gemini Live callbacks. Normal voice also uses them in direct PCM mode.
        GeminiLiveService.shared.onInputTranscription = { [weak self] (text: String) in
            guard let self, self.isDirectGeminiVoiceMode else { return }
            if self.directGeminiAwaitingNewInput {
                self.userTranscript = ""
                self.aiTranscript = ""
                self.historyLastLiveReply = ""
                self.directGeminiAwaitingNewInput = false
                // Gemini owns endpointing in raw-PCM mode. The first input-transcript fragment is
                // the closest client-side boundary we receive, so use it as the approximate turn
                // commit marker for diagnostics. Secure STT mode uses the exact local VAD path.
                MetricsCollector.shared.markSpeechEnd()
                MetricsCollector.shared.markCommit(
                    backend: AIBackendType.geminiLive.rawValue,
                    model: nil,
                    ttsEngine: "gemini-audio"
                )
            }
            self.userTranscript += text
            self.agentState = .listening
            self.armDirectGeminiResponseWatchdog()
        }

        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
            guard let self else { return }
            MetricsCollector.shared.markFirstToken()
            self.directGeminiResponseWatchdogTask?.cancel()
            self.directGeminiResponseWatchdogTask = nil
            // Gemini sends outputAudioTranscription incrementally (often word/phrase fragments).
            // Preserve the full reply for the live UI and persisted History.
            self.aiTranscript += text
        }

        GeminiLiveService.shared.onInterrupted = { [weak self] in
            guard let self, self.isDirectGeminiVoiceMode else { return }
            // The user's barge-in starts a new semantic turn immediately. Keep the same socket/mic;
            // only reset transcript bookkeeping so the next utterance does not concatenate onto the
            // previous turn.
            self.directGeminiAwaitingNewInput = true
            self.agentState = .listening
            DiagnosticLogger.shared.log("Voice", "Gemini barge-in kept persistent conversation open")
        }

        GeminiLiveService.shared.onToolStatusChanged = { [weak self] (toolName: String?, running: Bool) in
            guard let self, self.isDirectGeminiVoiceMode else { return }
            self.currentToolName = running ? toolName : nil
            if running {
                self.directGeminiResponseWatchdogTask?.cancel()
                self.directGeminiResponseWatchdogTask = nil
                self.agentState = .toolRunning
            } else if self.isSessionActive {
                self.agentState = .thinking
                self.armDirectGeminiResponseWatchdog()
            }
        }

        GeminiLiveService.shared.onDisconnected = { [weak self] in
            guard let self, self.isSessionActive, self.isDirectGeminiVoiceMode else { return }
            // This callback is reached only after Gemini's bounded reconnect attempts are exhausted
            // (intentional stop has already released direct mode). Never leave a dead mic owner.
            self.recoverDirectConversationToWake(reason: "Gemini reconnect attempts exhausted")
        }

        GeminiLiveService.shared.onTurnComplete = { [weak self] in
            guard let self else { return }
            self.directGeminiResponseWatchdogTask?.cancel()
            self.directGeminiResponseWatchdogTask = nil
            // A response that was explicitly stopped can still deliver a late server boundary.
            // Never reopen the microphone/conversation loop after the session was ended.
            guard self.isSessionActive || self.isLiveVideoMode else {
                DiagnosticLogger.shared.log("Voice", "Ignored Gemini turnComplete while session inactive")
                return
            }
            self.agentState = self.isLiveVideoMode ? .liveVideo : .listening
            // History: persist this Gemini Live exchange (transcript only, no frames).
            self.recordLiveTurn()
            if self.isDirectGeminiVoiceMode {
                self.directGeminiAwaitingNewInput = true
                self.armDirectGeminiConversationTimeout()
            } else {
                self.voiceCommandService.enterConversationMode()
            }
        }
    }

    /// Start listening for wake word
    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }
        guard !voiceCommandService.isWakeRecoverySuppressed else {
            DiagnosticLogger.shared.log("Voice", "Wake listener start skipped: direct Gemini owns microphone")
            return
        }

        // Configure audio for glasses before starting to listen
        configureAudioForGlasses()

        do {
            try voiceCommandService.startListening()
            isVoiceReady = true
            print("[VoiceAgent] Started wake word listening - READY")
        } catch {
            print("[VoiceAgent] Failed to start listening: \(error)")
            isVoiceReady = false
            reportVoiceError(
                error.localizedDescription,
                spoken: "Não consegui iniciar o microfone. Verifique o áudio e tente novamente."
            )
        }
    }

    // MARK: - Command routing

    /// Send command to AI backend
    private func sendCommand(_ command: String) async {
        let lowerCommand = command.lowercased()

        // Deterministic stop routing shared with the speech recognizer and covered by pure tests.
        let isStopCommand = VoiceStopMatching.isBareStopCommand(lowerCommand)

        if isStopCommand {
            print("[VoiceAgent] Stop command detected - full stop")
            performFullStop()
            return
        }

        // Check for live video mode commands
        let startLiveKeywords = ["start video stream", "start live video", "start video", "start streaming",
                                 "enable video", "live mode", "go live", "video mode"]

        let isStartLiveCommand = startLiveKeywords.contains { lowerCommand.contains($0) }
        let isStopLiveCommand = VoiceStopMatching.isLiveVideoStopCommand(lowerCommand)

        // Handle live video mode commands
        if isStartLiveCommand {
            print("[VoiceAgent] Starting live video mode...")
            await startLiveVideoMode()
            return
        }

        if isStopLiveCommand {
            print("[VoiceAgent] Stopping live video mode...")
            await stopLiveVideoMode()
            return
        }

        // If in live video mode, route by which live backend is driving it.
        if isLiveVideoMode {
            if activeLiveService == nil {
                // Local (SmolVLM2) live mode: STT is the input path, so every command lands here.
                // Answer it against the latest glasses frame.
                await handleLocalLiveVideoCommand(command)
            } else if activeLiveService === geminiLive {
                // Cloud modes stream audio directly, so this shouldn't be reached — but Gemini
                // can accept a text turn as a fallback. OpenAI Realtime is audio-only here.
                do {
                    try await geminiLive.sendText(command)
                } catch {
                    print("[VoiceAgent] Failed to send to Gemini Live: \(error)")
                }
            }
            return
        }

        // Drop only EXACT-duplicate commands fired within a few seconds. The speech
        // recognizer can emit the same phrase twice (partial + final), which double-fired
        // photo capture. A *different* follow-up question must still go through, even while
        // the previous answer is generating/speaking.
        let now = Date()
        if command == lastProcessedCommand, now.timeIntervalSince(lastProcessedAt) < 4 {
            print("[VoiceAgent] Ignoring duplicate command within 4s: \(command)")
            return
        }
        lastProcessedCommand = command
        lastProcessedAt = now

        // Face recognition on CLOUD backends: classify via the on-device model (if loaded) up front.
        // On the Local backend we DON'T do this — routing is merged into the single generation below
        // so we never run two Gemma generations per command (memory/jetsam).
        if settingsManager.settings.aiBackend != .localGemma {
            if await handleFaceCommandIfNeeded(command) {
                agentState = isSessionActive ? .listening : .idle
                return
            }
        }

        agentState = .thinking

        // Deterministic PC browser actions do not need an LLM. OpenClaw Gateway exposes
        // tools.invoke, so explicit commands such as "no meu computador abra o YouTube" can still
        // work when the provider configured on the PC is quota-limited. If browser policy/plugin is
        // unavailable, fall through to the normal OpenClaw agent exactly as before.
        if settingsManager.settings.aiBackend == .openClaw,
           let website = directOpenClawWebsiteRequest(command) {
            do {
                try await OpenClawService.shared.openWebsiteDirectly(urlString: website.url)
                let confirmation = "Abri \(website.label) no seu computador."
                aiTranscript = confirmation
                speakResponse(confirmation)
                return
            } catch {
                DiagnosticLogger.shared.log(
                    "OpenClaw",
                    "Direct PC action unavailable; falling back to agent: \(error.localizedDescription)"
                )
            }
        }

        // Check if this is a vision-related command
        // Keywords for "take a photo" - capture and send to OpenClaw
        let photoKeywords = ["take a photo", "take a picture", "take photo", "take picture",
                            "capture a photo", "capture photo", "snap a photo", "snap a picture",
                            "what do you see", "what are you looking at", "look at this",
                            "what's in front of me", "describe what you see", "what is this",
                            "what am i looking at", "can you see"]

        let isPhotoCommand = photoKeywords.contains { lowerCommand.contains($0) }

        // Drive whichever backend is selected through the AIBackend protocol — capabilities
        // (localLLM, supportsImageInput) decide the path, not concrete service types.
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        do {
            if let llm = backend.localLLM {
                // On-device routing brain (Gemma / Apple Intelligence): one generation that
                // routes faces, web search, native tools, or answers.
                await handleLocalCommand(command, llm: llm, isPhotoCommand: isPhotoCommand)
            } else if isPhotoCommand && backend.supportsImageInput {
                print("[VoiceAgent] Photo command on \(backend.backendType.displayName) — capturing...")
                await captureAndSendPhoto(withPrompt: command)
            } else {
                try await backend.sendMessage(command, imageData: nil)
            }
            // OpenAI is plain request/response with no session to keep "thinking" alive —
            // restore the listening state inline. The others restore via their callbacks.
            if backend.backendType == .openAI {
                agentState = isSessionActive ? .listening : .idle
            }
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle
        }
    }

    /// Narrow deterministic parser for direct PC website actions. Keep this intentionally
    /// conservative: everything else remains an agent request. More sites/actions can be added once
    /// their OpenClaw tool schemas are validated on the user's runtime.
    private func directOpenClawWebsiteRequest(_ command: String) -> (url: String, label: String)? {
        let n = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let asksOpen = ["abra", "abrir", "abre", "open"].contains { n.contains($0) }
        let targetsPC = ["computador", "meu pc", "no pc", "computer"].contains { n.contains($0) }
        guard asksOpen, targetsPC else { return nil }

        if n.contains("youtube") {
            return ("https://www.youtube.com", "o YouTube")
        }
        return nil
    }

    // MARK: - Live Video Mode

    /// Start live video mode - Gemini handles both audio and video
    private func startLiveVideoMode() async {
        guard !isLiveVideoMode else {
            print("[VoiceAgent] Already in live video mode")
            return
        }

        guard glassesManager.isRegistered else {
            ttsService.speak("Please connect your glasses first")
            return
        }

        // Fully on-device live video: with SmolVLM2 loaded as the local backend, keep the glasses
        // camera streaming and answer each spoken question against the latest frame. No cloud,
        // no WebSocket — Apple STT keeps listening and the reply is spoken via the selected TTS.
        if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
            await startLocalLiveVideoMode()
            return
        }

        // Pick the live backend: OpenAI Realtime when OpenAI is the selected + configured backend,
        // otherwise Gemini Live (the default video provider for every other backend).
        guard let (service, label) = resolveLiveService() else {
            ttsService.speak("Please configure your Gemini or OpenAI API key in settings")
            return
        }
        activeLiveService = service

        print("[VoiceAgent] Starting live video mode via \(label)...")

        // Stop VoiceCommandService - the live backend will handle audio directly
        voiceCommandService.stopListening()

        // Stop TTS if speaking
        ttsService.stop()
        geminiStreamingTTS.stop()
        KokoroTTSService.shared.stop()

        // Match the audio pipeline to the backend's sample rates (Gemini 16k in / 24k out,
        // OpenAI 24k in / 24k out) before starting capture/playback.
        audioCapture.targetSampleRate = Double(service.inputSampleRate)
        audioPlayback.inputSampleRate = Double(service.outputSampleRate)

        // Start glasses streaming
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }

        // Connect to the live backend
        do {
            try await service.connect()
        } catch {
            errorMessage = "Failed to connect to \(label): \(error.localizedDescription)"
            activeLiveService = nil
            // Cleanup: stop streaming and restart voice commands
            if glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
            do {
                try voiceCommandService.startListening()
                voiceCommandService.enterConversationMode()
            } catch {
                print("[VoiceAgent] Failed to restart voice commands: \(error)")
            }
            return
        }

        // Setup live backend callbacks
        setupLiveVideoCallbacks(service)

        // Setup audio capture → live backend
        audioCapture.onAudioCaptured = { [weak service] data in
            service?.sendAudio(data: data)
        }

        // Setup audio playback
        do {
            try audioPlayback.setup()
        } catch {
            print("[VoiceAgent] Failed to setup audio playback: \(error)")
        }

        // Start audio capture
        do {
            try audioCapture.startCapture()
        } catch {
            errorMessage = "Failed to start audio capture: \(error.localizedDescription)"
            await service.disconnect()
            activeLiveService = nil
            voiceCommandService.enterConversationMode()
            return
        }

        // Setup video frame routing to the live backend
        glassesManager.onVideoFrame = { [weak service] image in
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                service?.sendVideoFrame(imageData: jpegData)
            }
        }

        isLiveVideoMode = true
        agentState = .liveVideo

        print("[VoiceAgent] ✓ Live video mode active - \(label) handling audio + video")

        // Announce to user
        ttsService.speak("Live video mode active")
    }

    /// Resolve which live-video backend to use, or nil if none is configured.
    /// - OpenAI selected + configured → OpenAI Realtime
    /// - otherwise Gemini if configured (default video provider), else OpenAI if configured.
    private func resolveLiveService() -> (service: any LiveVideoService, label: String)? {
        let settings = settingsManager.settings
        if settings.aiBackend == .openAI && settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        if settings.isGeminiConfigured {
            return (geminiLive, "Gemini Live")
        }
        if settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        return nil
    }

    /// Fully on-device live video (SmolVLM2). Unlike the cloud modes, audio stays on the normal
    /// Apple STT path — we just keep the glasses camera streaming and mark the mode active, so
    /// each spoken question is answered against the latest frame (see sendCommand). Replies
    /// speak through the selected TTS engine as usual.
    private func startLocalLiveVideoMode() async {
        print("[VoiceAgent] Starting local live video mode (SmolVLM2)...")

        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            ttsService.speak("I couldn't start the glasses camera")
            return
        }

        // The glasses' Bluetooth HFP mic can't run while their camera streams (it goes deaf —
        // the PR #15 lesson; photo mode survives because its stream is momentary). Live mode
        // streams continuously, so force the phone mic + speaker for the whole session and
        // rebuild recognition on that route. The preferred route is restored on stop.
        voiceCommandService.stopListening()
        try? AudioSessionManager.shared.configureForPhone()
        do {
            try voiceCommandService.startListening()
        } catch {
            print("[VoiceAgent] Failed to restart STT on phone mic: \(error)")
        }

        // Stay in conversation mode so follow-ups don't need the wake word.
        voiceCommandService.enterConversationMode()

        isLiveVideoMode = true
        agentState = .liveVideo

        print("[VoiceAgent] ✓ Local live video mode active - SmolVLM2 answering on latest frame")
        ttsService.speak("Live video mode active, on device")
    }

    /// Answer a spoken question in local live video mode using a fresh, settled glasses frame.
    private func handleLocalLiveVideoCommand(_ command: String) async {
        agentState = .thinking
        // Let head motion settle and grab the freshest frame, so we describe the CURRENT view
        // rather than a stale/motion-blurred one the Bluetooth stream delivered a beat ago.
        guard let frame = await freshestGlassesFrame(settle: 0.3, maxWait: 1.0),
              let jpeg = frame.jpegData(compressionQuality: 0.6) else {
            speakResponse("I couldn't get a clear view just now — hold still a second and ask again.")
            agentState = .liveVideo
            return
        }
        do {
            // Strip "take a photo"-style wording; the frame is already attached.
            let prompt = visionPromptFromCommand(command)
            try await GemmaLocalService.shared.sendMessage(prompt, imageData: jpeg)
        } catch {
            print("[VoiceAgent] Local live video inference failed: \(error)")
            speakResponse("Sorry, that didn't work. \(error.localizedDescription)")
        }
        if isLiveVideoMode { agentState = .liveVideo }
    }

    /// Wait a brief `settle` for head motion to stop, then return the freshest camera frame that's
    /// genuinely recent (stream not stalled). Falls back to whatever frame we have after `maxWait`.
    /// This is the "current view, not a stale glimpse" grab for live video.
    private func freshestGlassesFrame(settle: TimeInterval, maxWait: TimeInterval) async -> UIImage? {
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            // Accept only a frame received within the last 500ms — under heavy motion the BT stream
            // throttles and lastFrame goes stale; wait for a fresh one instead of describing it.
            if Date().timeIntervalSince(glassesManager.lastFrameTime) < 0.5,
               let f = glassesManager.lastFrame {
                return f
            }
            try? await Task.sleep(nanoseconds: 80_000_000)   // 80ms poll
        }
        return glassesManager.lastFrame   // fallback: better an old frame than nothing
    }

    /// Stop live video mode
    private func stopLiveVideoMode() async {
        guard isLiveVideoMode else {
            print("[VoiceAgent] Not in live video mode")
            return
        }

        print("[VoiceAgent] Stopping live video mode...")

        // Stop audio capture
        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil

        // Stop audio playback
        audioPlayback.teardown()

        // Disconnect the active live backend (Gemini or OpenAI Realtime)
        await activeLiveService?.disconnect()
        activeLiveService = nil

        // Stop glasses streaming
        if glassesManager.isStreaming {
            await glassesManager.stopStreaming()
        }

        // Restore video frame callback to Gemini Vision
        glassesManager.onVideoFrame = { [weak self] image in
            self?.geminiVision.sendVideoFrame(image)
        }

        isLiveVideoMode = false
        agentState = isSessionActive ? .listening : .idle

        // Local live mode forced the phone mic (HFP dies during camera streaming) and its STT
        // may still be running — stop it so the restart below picks up the preferred route.
        if voiceCommandService.isListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()

        // Always restart VoiceCommandService for wake word detection
        do {
            try voiceCommandService.startListening()
            if isSessionActive {
                // Continue conversation mode if session was active
                voiceCommandService.enterConversationMode()
                print("[VoiceAgent] Restarted voice commands in conversation mode")
            } else {
                // Just listen for wake word
                print("[VoiceAgent] Restarted voice commands for wake word detection")
            }
        } catch {
            print("[VoiceAgent] Failed to restart voice commands: \(error)")
        }

        print("[VoiceAgent] Live video mode stopped")
        ttsService.speak("Live video mode ended")
    }

    /// Setup live backend callbacks for audio/transcription (Gemini Live or OpenAI Realtime)
    private func setupLiveVideoCallbacks(_ service: any LiveVideoService) {
        // Audio from the model → playback
        service.onAudioReceived = { [weak self] data in
            self?.audioPlayback.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        service.onInputTranscription = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.userTranscript = text

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                let stopKeywords = ["stop video", "stop streaming", "stop live", "end video",
                                   "exit video", "disable video", "stop the video", "end live",
                                   // Hindi fallbacks (models sometimes transcribe English as Hindi)
                                   "स्टॉप", "वीडियो बंद", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    print("[VoiceAgent] Stop command detected in transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        service.onOutputTranscription = { [weak self] text in
            Task { @MainActor in
                self?.aiTranscript = text
            }
        }

        // Turn complete
        service.onTurnComplete = { [weak self] in
            Task { @MainActor in
                // History: persist this live-video exchange (transcript only, no frames).
                self?.recordLiveTurn()
            }
        }

        // Disconnection - handle reconnection or mode exit
        service.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isLiveVideoMode {
                    print("[VoiceAgent] Live backend disconnected unexpectedly")
                    await self.stopLiveVideoMode()
                }
            }
        }
    }

    /// Turn a spoken photo command into a clean vision question for a model that already has
    /// the image attached. Removes "take a picture / photo" trigger wording so the model
    /// describes the image instead of protesting that it can't take photos.
    private func visionPromptFromCommand(_ command: String) -> String {
        var s = command.lowercased()
        // Only strip explicit photo-capture wording — that's what makes a VLM refuse ("I can't
        // take photos"). Do NOT strip politeness/filler ("would you", "right now", "of this"):
        // removing those mid-sentence mangled real questions ("what am I looking at right now"
        // → "what am I looking at"; "would you tell me which plant" → "tell me which plant").
        let triggers = [
            "take a picture of this", "take a photo of this", "take a picture", "take a photo",
            "take photo", "take picture", "capture a photo", "capture photo", "snap a photo",
            "snap a picture", "go ahead and take"
        ]
        for t in triggers { s = s.replacingOccurrences(of: t, with: " ") }
        s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leftover connective prefixes left after removing the trigger ("...and tell me…").
        for prefix in ["and ", "of this ", "of ", "please "] {
            while s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        if s.count < 3 {
            return "What is the main object in this image? Name it specifically and describe its key visible details in 2–3 sentences."
        }
        return "Look closely at the image and answer specifically and concretely: \(s)"
    }

    // MARK: - POV Recording

    /// Toggle a demo recording of the glasses point-of-view (video) plus the phone mic (audio,
    /// which captures the scene sound and the assistant's spoken reply played out the speaker).
    /// The result is saved to Photos for sharing.
    func toggleRecording() {
        if isRecording {
            sessionRecorder.stop()   // finishes async; `onFinished` resets state + reports the save
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard glassesManager.isRegistered else {
            errorMessage = "Connect your glasses first to record."
            return
        }
        // Recording needs a live frame stream; start it if the user isn't already in live video.
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            errorMessage = "Couldn't start the glasses camera to record."
            return
        }

        // Route the raw glasses frames into the recorder. This is separate from `onVideoFrame`
        // (which feeds the AI in live mode), so recording and live vision can run together.
        glassesManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.sessionRecorder.appendVideoSampleBuffer(sampleBuffer)
        }

        sessionRecorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.isRecording = false
            self.glassesManager.onVideoSampleBuffer = nil
            self.showRecordingStatus(url != nil ? "Saved to Photos" : "Couldn't save recording")
        }

        do {
            try sessionRecorder.start()
            isRecording = true
        } catch {
            glassesManager.onVideoSampleBuffer = nil
            errorMessage = "Recording failed to start: \(error.localizedDescription)"
        }
    }

    /// Show a brief status message after a recording finishes, then clear it.
    private func showRecordingStatus(_ text: String) {
        recordingStatus = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.recordingStatus == text { self?.recordingStatus = nil }
        }
    }

    // MARK: - Face recognition

    /// Route face-recognition commands using the on-device model as an intent classifier
    /// (agentic — no keyword matching, like OpenGlasses' face_recognition tool). Returns true
    /// if the command was a face command and was handled.
    private func handleFaceCommandIfNeeded(_ command: String) async -> Bool {
        // Fast deterministic path for the explicit commands we actually use in Portuguese/English.
        // This keeps face recognition available on OpenClaw/OpenAI even when the local MLX model is
        // not loaded. Ambiguous requests still fall through to the on-device classifier/model.
        if let intent = deterministicFaceIntent(command) {
            await handleFaceIntent(intent)
            return true
        }

        guard let intent = await GemmaLocalService.shared.classifyFaceIntent(command) else {
            return false   // model not loaded, or not a face command
        }
        await handleFaceIntent(intent)
        return true
    }

    private func deterministicFaceIntent(_ command: String) -> GemmaLocalService.FaceIntent? {
        let normalized = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func suffix(after markers: [String]) -> String? {
            for marker in markers {
                if let range = command.range(
                    of: marker,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) {
                    let value = command[range.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    if !value.isEmpty { return value }
                }
            }
            return nil
        }

        let listPhrases = [
            "quem voce conhece", "quais pessoas voce conhece", "liste as pessoas que voce conhece",
            "list known faces", "who do you know"
        ]
        if listPhrases.contains(where: normalized.contains) {
            return .init(action: "list", name: "")
        }

        if normalized.hasPrefix("esqueca ") || normalized.hasPrefix("forget ") {
            let name = suffix(after: ["esqueça ", "esqueca ", "forget "]) ?? ""
            return .init(action: "forget", name: name)
        }

        let visualCues = [
            "essa pessoa", "esse rosto", "essa face", "pessoa na minha frente",
            "this person", "this face", "person in front"
        ]
        let hasVisualCue = visualCues.contains(where: normalized.contains)
        let rememberCues = ["lembre", "memorize", "cadastre", "remember", "save this"]
        if hasVisualCue && rememberCues.contains(where: normalized.contains) {
            let name = suffix(after: [" como ", " as "]) ?? ""
            return .init(action: "remember", name: name)
        }

        let identifyCues = [
            "quem e essa pessoa", "quem e esse rosto", "voce conhece essa pessoa",
            "reconheca essa pessoa", "identifique essa pessoa",
            "who is this person", "who is this face", "recognize this person", "identify this person"
        ]
        if identifyCues.contains(where: normalized.contains) {
            return .init(action: "identify", name: "")
        }

        return nil
    }

    /// Shared handling for the on-device text models (Gemma / Apple Foundation): one agentic
    /// generation that routes a face action, a web search, or a direct spoken answer.
    private func handleLocalCommand(_ command: String, llm: LocalTextLLM, isPhotoCommand: Bool) async {
        if isPhotoCommand {
            // SmolVLM2 handles photos fully on-device; other local models are text-only
            // (Gemma E2B's vision hit the jetsam limit — see GemmaLocalModel.supportsOnDeviceVision).
            if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
                print("[VoiceAgent] Photo command on local SmolVLM2 — capturing...")
                await captureAndSendPhoto(withPrompt: command)
                return
            }
            agentState = isSessionActive ? .listening : .idle
            speakResponse("This on-device model is text only. For camera questions, select SmolVLM2 as your local model, or switch to Gemini or OpenClaw in Settings.")
            return
        }
        // Route the command. With Apple TTS, stream the answer: speak sentences as they generate.
        // Backends that can't stream (Apple FM) fall back to a plain route via the protocol's
        // default implementation — onPartial simply never fires. Face/tool routes emit JSON
        // starting with "{", so we only begin speaking once the streamed output's first non-space
        // char proves it's a plain answer — never for a structured route.
        let result: LocalAgent.RouteResult
        if canStreamSpeech {
            ttsStreaming = false
            ttsStreamSpokenChars = 0
            result = await llm.routeCommandStreaming(command) { [weak self] cumulative in
                guard let self else { return }
                let lead = cumulative.trimmingCharacters(in: .whitespacesAndNewlines).first
                guard let lead, lead != "{" else { return }   // JSON route → don't speak
                self.feedStreamingSpeech(cumulative, isFinal: false)
            }
        } else {
            result = await llm.routeCommand(command)
        }

        switch result {
        case .face(let intent):
            // Safety: if we mis-started streaming (answer contained a stray "{"), cancel it.
            if ttsStreaming { stopActiveStreamingTTS(); ttsStreaming = false }
            await handleFaceIntent(intent)
        case .webSearch(let query):
            if ttsStreaming { stopActiveStreamingTTS(); ttsStreaming = false }
            NSLog("[OV] web search: \"%@\"", query)
            var result = await WebSearchService.search(query)
            // Agentic retry: if the first query found nothing, let the model reformulate once.
            if result.isEmpty, let better = await llm.reformulateSearchQuery(question: command, triedQuery: query) {
                NSLog("[OV] web search retry: \"%@\"", better)
                result = await WebSearchService.search(better)
            }
            let answer = await llm.answerWithSearchResult(question: command, result: result)
            speakResponse(answer)   // separate generation — not streamed here
            ConversationContext.shared.record(user: command, assistant: answer)
        case .answer(let text):
            if ttsStreaming {
                feedStreamingSpeech(text, isFinal: true)   // flush the tail, close the session
            } else {
                speakResponse(text)   // Kokoro, or non-streaming backend
            }
            ConversationContext.shared.record(user: command, assistant: text)
        }
        // Generation finishes well before the voice does (several sentences stay queued in TTS).
        // Don't stomp the state back to .listening while the reply is still being spoken — the
        // TTS-finished observers handle that transition at the right moment.
        if !ttsService.isSpeaking && !KokoroTTSService.shared.isSpeaking {
            agentState = isSessionActive ? .listening : .idle
        }
    }

    /// Carry out a face action (camera capture + Apple Vision), shared by the cloud-backend
    /// classifier path and the Local-backend single-pass router.
    private func handleFaceIntent(_ intent: GemmaLocalService.FaceIntent) async {
        let face = FaceRecognitionService.shared
        switch intent.action {
        case "identify":
            agentState = .thinking
            guard let image = await currentFaceImage() else {
                speakResponse("Não consegui acessar uma câmera para reconhecer a pessoa.")
                return
            }
            speakResponse(await face.identify(in: image))

        case "remember":
            agentState = .thinking
            guard !intent.name.isEmpty else {
                speakResponse("Claro. Qual é o nome dessa pessoa?")
                return
            }
            guard let image = await currentFaceImage() else {
                speakResponse("Não consegui acessar uma câmera para cadastrar essa pessoa.")
                return
            }
            speakResponse(await face.rememberFace(name: intent.name, from: image))

        case "forget":
            speakResponse(face.forgetFace(name: intent.name))

        case "list":
            speakResponse(face.listKnownFaces())

        default:
            break
        }
    }

    /// Face recognition is camera-source agnostic. Prefer the Ray-Ban POV camera when it is
    /// actually connected; otherwise take a one-shot photo with the iPhone rear camera.
    private func currentFaceImage() async -> UIImage? {
        do {
            let capture = try await VisionCaptureService.shared.captureImage(
                preferred: .automatic,
                keepGlassesStreaming: isLiveVideoMode
            )
            DiagnosticLogger.shared.log("Face", "Captured face frame source=\(capture.source.rawValue)")
            return capture.image
        } catch {
            DiagnosticLogger.shared.log("Face", "Camera capture failed: \(error.localizedDescription)")
            errorMessage = "Face camera failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Photo capture

    /// Get a fresh UIImage frame from the glasses camera, then turn the camera off
    /// ("click and go") — unless we're in live video mode.
    private func currentGlassesImage() async -> UIImage? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming { await glassesManager.startStreaming() }
        var frame: UIImage?
        for _ in 0..<40 {   // up to ~4s for a fresh frame
            if let f = glassesManager.lastFrame { frame = f; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if frame == nil { frame = glassesManager.lastFrame }
        if glassesManager.isStreaming && !isLiveVideoMode {
            await glassesManager.stopStreaming()
        }
        // Do NOT touch the audio stack here. Tearing down / rebuilding the recognizer around the
        // camera is what broke the HFP mic: every rebuild forces a fresh Bluetooth SCO negotiation,
        // which the glasses can't service right after streaming (mic stays deaf for tens of seconds,
        // with an audible reconnect chirp per attempt). OpenGlasses keeps its wake-word engine + mic
        // tap alive straight through photo capture — audio just gaps during the stream and resumes
        // into the same running engine. We now do the same; see restartRecognition()'s engine check.
        return frame
    }

    /// Send a prompt (optionally with a photo) to whichever backend is currently selected.
    private func sendPromptToActiveBackend(_ prompt: String, imageData: Data?) async throws {
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        // Backends that can't take an image (Apple FM text-only, Gemini streams video live)
        // receive just the prompt.
        try await backend.sendMessage(prompt, imageData: backend.supportsImageInput ? imageData : nil)
    }

    private func captureAndSendPhoto(withPrompt prompt: String) async {
        // Try to get an image from various sources
        var imageData: Data?
        var startedStreamingForPhoto = false

        // Start streaming if glasses are registered but not streaming. `startStreaming()` only
        // returns after `session.start()` completes (isStreaming is already true here), so the
        // old "poll up to 3s for isStreaming" loop + fixed 500ms sleep were dead weight that just
        // kept the LED on longer. freshLiveFrame() below already waits for the first real frame,
        // so drop the artificial delay entirely.
        if glassesManager.isRegistered && !glassesManager.isStreaming {
            print("[VoiceAgent] Starting glasses camera stream for photo...")
            await glassesManager.startStreaming()
            startedStreamingForPhoto = true
        }

        // Capture straight from the live video stream. The glasses' one-shot photo API
        // (session.capturePhoto) doesn't reliably deliver on this model/SDK — it times out
        // after 5s — whereas a live frame is available immediately. freshLiveFrame() ensures
        // the stream is running, waits for a fresh frame, and restarts a stalled stream.
        imageData = await freshLiveFrame()

        // No Ray-Ban frame (not connected, permission/session failure, etc.) → use the phone camera.
        // This also makes photo/vision testing possible before the glasses camera path is ready.
        if imageData == nil {
            do {
                let phoneImage = try await PhoneCameraService.shared.capturePhoto()
                imageData = phoneImage.jpegData(compressionQuality: 0.85)
                if imageData != nil {
                    DiagnosticLogger.shared.log("Vision", "Photo fallback captured with iPhone rear camera")
                }
            } catch {
                DiagnosticLogger.shared.log("Vision", "iPhone camera fallback failed: \(error.localizedDescription)")
            }
        }

        NSLog("[OV] captureAndSendPhoto result: %@ (streaming=%@, registered=%@)",
              imageData == nil ? "NO IMAGE" : "\(imageData!.count) bytes",
              glassesManager.isStreaming ? "yes" : "no",
              glassesManager.isRegistered ? "yes" : "no")

        // "Click and go": now that we have the photo, turn the glasses camera off immediately —
        // before the (multi-second) model inference — so the LED doesn't stay on. Repeat photo
        // commands restart the camera reliably via freshLiveFrame(). Skip in live video mode.
        if imageData != nil && glassesManager.isStreaming && !isLiveVideoMode {
            NSLog("[OV] photo captured — stopping camera (click and go)")
            await glassesManager.stopStreaming()
        }

        // Send with or without image
        do {
            if let imageData = imageData {
                // The image is attached, so strip the "take a picture" wording — otherwise the
                // VLM replies "I can't take photos / please provide an image" before describing.
                let visionPrompt = visionPromptFromCommand(prompt)
                NSLog("[OV] Sending message with photo (%d bytes), prompt: \"%@\"", imageData.count, visionPrompt)
                try await sendPromptToActiveBackend(visionPrompt, imageData: imageData)
            } else {
                NSLog("[OV] No image available — capture returned nil; NOT sending to model")
                // Don't send a degraded text-only prompt to the model — that's what makes it
                // reply "please provide an image". Tell the user directly and stop.
                errorMessage = "Couldn't capture a photo from the glasses or iPhone camera. Try again."
                speakResponse("Não consegui capturar uma imagem nem dos óculos nem da câmera do iPhone. Tente novamente.")
            }
        } catch {
            print("[VoiceAgent] Failed to send: \(error)")
            errorMessage = "Failed to send: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle

            // Stop streaming on error if we started it for this photo
            if startedStreamingForPhoto && glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
        }
    }

    /// Capture photo from glasses and return the data
    private func capturePhotoFromGlasses() async -> Data? {
        // Clear any stale photo before requesting a fresh capture.
        glassesManager.lastPhotoData = nil
        NSLog("[OV] capturePhotoFromGlasses: requesting capture (streaming=%@)", glassesManager.isStreaming ? "yes" : "no")
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 5 seconds)
        for _ in 0..<50 {
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                NSLog("[OV] Photo captured: %d bytes", photoData.count)
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        NSLog("[OV] Photo capture TIMED OUT after 5s")
        return nil
    }

    /// Force a fresh live video frame, restarting the stream if it has stalled.
    /// More reliable than the one-shot photo capture for repeated requests in a session.
    private func freshLiveFrame() async -> Data? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        // Wait for a NEW frame (clear first so we don't reuse a stale one).
        glassesManager.lastFrame = nil
        for _ in 0..<25 { // up to ~2.5s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Stream appears stalled — restart it once and retry.
        NSLog("[OV] live frame stalled — restarting stream")
        await glassesManager.stopStreaming()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await glassesManager.startStreaming()
        glassesManager.lastFrame = nil
        for _ in 0..<30 { // up to ~3s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired after restart")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[OV] freshLiveFrame: STILL no frame after restart")
        return nil
    }

    // MARK: - Glasses Video Integration

    /// Setup glasses callbacks to stream video to Gemini Vision
    private func setupGlassesCallbacks() {
        print("[VoiceAgent] Setting up glasses video callbacks...")

        // Connect video frames from glasses to Gemini Vision (for live feed)
        // Note: GeminiVisionService.sendVideoFrame already throttles to 1fps
        glassesManager.onVideoFrame = { [weak self] image in
            guard let self else { return }
            // Send frame to Gemini Vision for live analysis
            self.geminiVision.sendVideoFrame(image)

            // Log periodically (every 30 frames = ~1 second at 30fps)
            Task { @MainActor in
                self.videoFrameCount += 1
                if self.videoFrameCount % 30 == 0 {
                    print("[VoiceAgent] Video frames processed: \(self.videoFrameCount)")
                }
            }
        }

        // Photo captured callback (for OpenClaw photo analysis)
        glassesManager.onPhotoCaptured = { data in
            print("[VoiceAgent] Photo captured: \(data.count) bytes")
            // Photos are handled via OpenClaw's attachment system
        }

        print("[VoiceAgent] Glasses callbacks configured")
    }

    private func reportVoiceError(_ message: String, spoken: String) {
        errorMessage = message
        DiagnosticLogger.shared.log("Voice", "ERROR: \(message)")
        // Use the system voice for error reporting because it is always available, even when the
        // selected neural/cloud TTS failed or was never initialized.
        if !ttsService.isSpeaking {
            ttsService.speak(spoken)
        }
    }

    // MARK: - TTS Integration

    /// True when the active speech engine is Apple's system voice. Kokoro also supports streaming
    /// in Build 40, but Apple remains the no-GPU-contention path.
    private var usingAppleTTS: Bool {
        !(settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady)
    }

    /// Feed the streamed reply to the active TTS engine sentence-by-sentence. `cumulative` is the full text so
    /// far (the local model emits a growing snapshot each token). On non-final calls we speak only
    /// the sentences that have fully completed; on the final call we flush whatever remains.
    private func feedStreamingSpeech(_ cumulative: String, isFinal: Bool) {
        // Open a streamed utterance session on first content.
        if !ttsStreaming {
            guard !cumulative.isEmpty else { return }
            ttsStreaming = true
            ttsStreamSpokenChars = 0
            beginActiveStreamingTTS()
        }

        // The portion not yet handed to the speech queue.
        let spokenClamped = min(ttsStreamSpokenChars, cumulative.count)
        let start = cumulative.index(cumulative.startIndex, offsetBy: spokenClamped)
        let pending = cumulative[start...]

        if isFinal {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { speakActiveStreamingChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            endActiveStreamingTTS()
            ttsStreaming = false
            recordAssistantReply(cumulative)   // history: streamed reply is complete
            return
        }

        // Speak everything up to the last completed sentence boundary in the pending text.
        guard let boundary = TextChunking.lastSentenceBoundary(in: String(pending)) else { return }
        let pendingStr = String(pending)
        let sentence = String(pendingStr[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 2 else { return }   // don't voice a stray "." or "?"
        speakActiveStreamingChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
    }

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        recordAssistantReply(text)
        MetricsCollector.shared.markTTSRequested()
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            // Same configured Google voice as Gemini Live (Charon by default).
            geminiStreamingTTS.speak(text)
        } else if settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady {
            Task { await KokoroTTSService.shared.speak(text, voice: settingsManager.settings.kokoroVoice) }
        } else {
            ttsService.speak(text)
        }
    }

    // MARK: - History

    /// History: persist the assistant's reply, but only when it answers a recorded user command —
    /// system utterances ("Live video mode active", connection errors) stay out of History.
    private func recordAssistantReply(_ text: String) {
        guard historyAwaitingReply else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        ConversationManager.shared.addAssistantMessage(clean)
        historyAwaitingReply = false
    }

    /// History (live video / realtime modes): commands don't pass through onCommandCaptured there,
    /// so record the user+assistant pair at each turn boundary. Transcript only — video frames are
    /// never stored (same policy as Meta's live AI history).
    private func recordLiveTurn() {
        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = aiTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply != historyLastLiveReply else { return }
        // Normal wake-word commands were already persisted by onCommandCaptured. Live-video /
        // realtime paths bypass that callback, so only those need the user message added here.
        if !historyAwaitingReply, !user.isEmpty { ConversationManager.shared.addUserMessage(user) }
        ConversationManager.shared.addAssistantMessage(reply)
        historyLastLiveReply = reply
        historyAwaitingReply = false
    }

    // MARK: - Tool Handlers (OpenClaw device-side tools)

    /// Handle take_photo tool call
    private func handleTakePhotoTool(completion: @escaping (String) -> Void) async {
        print("[VoiceAgent] Handling take_photo tool")

        if glassesManager.isStreaming {
            // Capture from glasses
            await glassesManager.capturePhoto()

            // Wait for photo to be captured (via callback)
            // Set up one-time handler for the photo
            let originalHandler = glassesManager.onPhotoCaptured
            glassesManager.onPhotoCaptured = { [weak self] data in
                // Restore original handler
                self?.glassesManager.onPhotoCaptured = originalHandler

                // Send photo to OpenClaw as attachment in next message
                Task {
                    do {
                        try await OpenClawService.shared.sendMessage("Here's the photo I just captured.", imageData: data)
                        completion("Photo captured and sent for analysis.")
                    } catch {
                        completion("Photo captured but failed to send: \(error.localizedDescription)")
                    }
                }
            }

            // Timeout after 5 seconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.glassesManager.onPhotoCaptured != nil {
                    self.glassesManager.onPhotoCaptured = originalHandler
                    completion("Photo capture timed out.")
                }
            }
        } else if let lastFrame = glassesManager.lastFrame,
                  let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            // Use last frame if available
            do {
                try await OpenClawService.shared.sendMessage("Here's what I can see.", imageData: jpegData)
                completion("Captured current view and sent for analysis.")
            } catch {
                completion("Failed to send image: \(error.localizedDescription)")
            }
        } else {
            do {
                let image = try await PhoneCameraService.shared.capturePhoto()
                guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
                    completion("The iPhone camera captured an image but JPEG conversion failed.")
                    return
                }
                try await OpenClawService.shared.sendMessage("Here's the photo I just captured with the iPhone camera.", imageData: jpegData)
                completion("Photo captured with the iPhone camera and sent for analysis.")
            } catch {
                completion("iPhone camera capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// Handle describe_scene tool call (uses Gemini Vision)
    private func handleDescribeSceneTool(args: [String: Any], completion: @escaping (String) -> Void) async {
        print("[VoiceAgent] Handling describe_scene tool")

        let prompt = args["prompt"] as? String ?? "Please describe what you see in this image."

        // Capture photo and send to OpenClaw for analysis
        if let lastFrame = glassesManager.lastFrame,
           let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            do {
                try await OpenClawService.shared.sendMessage(prompt, imageData: jpegData)
                completion("Image captured and sent for analysis.")
            } catch {
                completion("Failed to analyze scene: \(error.localizedDescription)")
            }
        } else if glassesManager.isStreaming {
            // Try to capture a photo
            await glassesManager.capturePhoto()
            // Wait briefly for photo
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                do {
                    try await OpenClawService.shared.sendMessage(prompt, imageData: photoData)
                    completion("Photo captured and sent for analysis.")
                } catch {
                    completion("Failed to send photo: \(error.localizedDescription)")
                }
            } else {
                completion("Failed to capture photo.")
            }
        } else {
            do {
                let image = try await PhoneCameraService.shared.capturePhoto()
                guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
                    completion("The iPhone camera captured an image but JPEG conversion failed.")
                    return
                }
                try await OpenClawService.shared.sendMessage(prompt, imageData: jpegData)
                completion("Scene captured with the iPhone camera and sent for analysis.")
            } catch {
                completion("iPhone camera capture failed: \(error.localizedDescription)")
            }
        }
    }
}
