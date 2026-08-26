from pathlib import Path
import subprocess

voice_path = Path("JARVIS/Services/Voice/VoiceCommandService.swift")
viewmodel_path = Path("JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift")
gemini_path = Path("JARVIS/Services/GeminiLive/GeminiLiveService.swift")
project_path = Path("project.yml")
notes_path = Path("JARVIS_BUILD_NOTES.md")

voice = voice_path.read_text(encoding="utf-8")
viewmodel = viewmodel_path.read_text(encoding="utf-8")
gemini = gemini_path.read_text(encoding="utf-8")
project = project_path.read_text(encoding="utf-8")
notes = notes_path.read_text(encoding="utf-8")


def replace_once(text, old, new, label):
    assert old in text, f"{label} anchor changed"
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# VoiceCommandService: a wake word opens a persistent conversational session.
# Once active, idle pulses must not tear the session down and force another wake.
# ---------------------------------------------------------------------------
voice = replace_once(
    voice,
    '''    /// True while Gemini owns the microphone as a direct PCM stream. App/lifecycle recovery paths
    /// must not start a second Apple Speech recognizer while this flag is set.
    var isWakeRecoverySuppressed: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
''',
    '''    /// True while Gemini owns the microphone as a direct PCM stream. App/lifecycle recovery paths
    /// must not start a second Apple Speech recognizer while this flag is set.
    var isWakeRecoverySuppressed: Bool = false

    /// ChatGPT-style conversation lifecycle: after the initial wake word, silence is only an idle
    /// pulse. It must NOT close the active conversation and require another wake phrase.
    var persistentConversationMode: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
''',
    "voice persistent conversation flag",
)

voice = replace_once(
    voice,
    '''    private func handleConversationTimeout() {
        guard state == .conversationMode else { return }

        if hasSpokenThisTurn {
            print("[VoiceCommand] User is speaking, extending conversation")
        } else {
            print("[VoiceCommand] Conversation timeout - no speech detected")
            DiagnosticLogger.shared.log("Voice", "Conversation timeout fired")
            exitConversationMode()
            onConversationTimeout?()
        }
    }
''',
    '''    private func handleConversationTimeout() {
        guard state == .conversationMode else { return }

        if hasSpokenThisTurn {
            print("[VoiceCommand] User is speaking, extending conversation")
            startConversationTimeout()
            return
        }

        if persistentConversationMode {
            // Stay in the same recognition/session loop. Restarting recognition clears stale STT
            // buffers while preserving the conversational state, just like a realtime voice call
            // that remains open through silence.
            DiagnosticLogger.shared.log("Voice", "Persistent conversation idle pulse; staying open")
            currentTranscription = ""
            lastSpeechRecognitionUpdateAt = nil
            vadCommitPending = false
            hasSpokenThisTurn = false
            restartRecognition()
            startConversationTimeout()
            onConversationTimeout?()
            return
        }

        print("[VoiceCommand] Conversation timeout - no speech detected")
        DiagnosticLogger.shared.log("Voice", "Conversation timeout fired")
        exitConversationMode()
        onConversationTimeout?()
    }
''',
    "voice persistent idle handling",
)


# ---------------------------------------------------------------------------
# Gemini Live: expose interruption/tool lifecycle and a bounded reconnect entrypoint.
# Tools run inside the same stateful session instead of appearing as a session boundary.
# ---------------------------------------------------------------------------
gemini = replace_once(
    gemini,
    '''    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?
''',
    '''    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var isToolRunning: Bool = false
    @Published var currentToolName: String?
    @Published var lastError: String?
''',
    "gemini tool state",
)

gemini = replace_once(
    gemini,
    '''    var onOutputTranscription: ((String) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?
''',
    '''    var onOutputTranscription: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onToolStatusChanged: ((String?, Bool) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?
''',
    "gemini runtime callbacks",
)

gemini = replace_once(
    gemini,
    '''        isSetupComplete = false
        isModelSpeaking = false
        pendingTurnComplete = false
        discardIncomingAudio = false
        ignoreNextTurnComplete = false
''',
    '''        isSetupComplete = false
        isModelSpeaking = false
        isToolRunning = false
        currentToolName = nil
        pendingTurnComplete = false
        discardIncomingAudio = false
        ignoreNextTurnComplete = false
''',
    "gemini close reset tool state",
)

gemini = replace_once(
    gemini,
    '''    func interrupt() async {
        guard isModelSpeaking || isProcessing || fallbackAudioPlayback.isPlaying else { return }

        pendingTurnComplete = false
''',
    '''    func interrupt() async {
        guard isModelSpeaking || isProcessing || fallbackAudioPlayback.isPlaying else { return }

        pendingTurnComplete = false
''',
    "gemini interrupt anchor",
)

# Add public recovery API after interrupt().
gemini = replace_once(
    gemini,
    '''        DiagnosticLogger.shared.log("Gemini", "Local barge-in: playback stopped; old PCM suppressed")
        print("[GeminiLive] Interrupted")
    }

    // MARK: - Send Video
''',
    '''        DiagnosticLogger.shared.log("Gemini", "Local barge-in: playback stopped; old PCM suppressed")
        print("[GeminiLive] Interrupted")
    }

    /// Rebuild the underlying Live WebSocket while preserving the latest session-resumption
    /// handle. Used by the conversation watchdog when the transport is alive-looking but silent.
    func recoverLiveSession(reason: String) async throws {
        guard !intentionalDisconnect else { throw AIBackendError.notConnected }
        DiagnosticLogger.shared.log("Gemini", "Conversation watchdog recovery requested: \\(reason)")
        try await reconnectImmediately(reason: reason)
    }

    // MARK: - Send Video
''',
    "gemini public silent recovery",
)

gemini = replace_once(
    gemini,
    '''            fallbackAudioPlayback.stop()
            DiagnosticLogger.shared.log("Gemini", "Server content interrupted")
        }
''',
    '''            fallbackAudioPlayback.stop()
            DiagnosticLogger.shared.log("Gemini", "Server content interrupted")
            onInterrupted?()
        }
''',
    "gemini interrupted callback",
)

gemini = replace_once(
    gemini,
    '''        var responses: [[String: Any]] = []
        for call in calls {
            guard let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            let result = await NativeToolRegistry.shared.execute(name: name, args: args)
            var response: [String: Any] = ["name": name, "response": ["result": result]]
            if let id = call["id"] as? String { response["id"] = id }  // echo id so Gemini pairs the response
            responses.append(response)
        }
''',
    '''        // Function calling in Gemini Live is synchronous: keep the realtime session open and
        // mark the turn as busy until every tool result has been sent back to the same socket.
        isProcessing = true
        var responses: [[String: Any]] = []
        for call in calls {
            guard let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            currentToolName = name
            isToolRunning = true
            onToolStatusChanged?(name, true)
            DiagnosticLogger.shared.log("Gemini", "Tool running in persistent session: \\(name)")

            let result = await NativeToolRegistry.shared.execute(name: name, args: args)

            isToolRunning = false
            currentToolName = nil
            onToolStatusChanged?(name, false)
            var response: [String: Any] = ["name": name, "response": ["result": result]]
            if let id = call["id"] as? String { response["id"] = id }  // echo id so Gemini pairs the response
            responses.append(response)
        }
''',
    "gemini persistent tool lifecycle",
)


# ---------------------------------------------------------------------------
# VoiceAgentViewModel: Conversation Runtime v2.
# - one wake opens the conversation
# - direct Gemini has no per-turn idle shutdown
# - non-realtime backends keep conversation mode alive through idle pulses
# - silent/fatal Gemini failures reconnect or atomically hand mic back to wake listener
# ---------------------------------------------------------------------------
viewmodel = replace_once(
    viewmodel,
    '''    private var isDirectGeminiVoiceMode = false
    private var directGeminiAwaitingNewInput = true
    private var directGeminiTimeoutTask: Task<Void, Never>?
''',
    '''    private var isDirectGeminiVoiceMode = false
    private var directGeminiAwaitingNewInput = true
    private var directGeminiTimeoutTask: Task<Void, Never>?
    private var directGeminiResponseWatchdogTask: Task<Void, Never>?
''',
    "viewmodel response watchdog state",
)

viewmodel = replace_once(
    viewmodel,
    '''                if settingsManager.settings.aiBackend == .geminiLive {
                    // Normal Gemini voice is now true audio-to-audio after the local wake word.
                    try startDirectGeminiVoiceMode()
                } else {
                    // Text backends keep Apple STT for command capture.
                    if voiceCommandService.authorizationStatus == .authorized {
                        if !voiceCommandService.isListening {
                            try? voiceCommandService.startListening()
                        }
                        voiceCommandService.enterConversationMode()
''',
    '''                if settingsManager.settings.aiBackend == .geminiLive {
                    // Native full-duplex audio owns the conversation after the one-time wake word.
                    voiceCommandService.persistentConversationMode = false
                    try startDirectGeminiVoiceMode()
                } else {
                    // Text backends still use Apple STT, but the conversation itself is persistent:
                    // silence no longer tears the session down and forces another wake phrase.
                    if voiceCommandService.authorizationStatus == .authorized {
                        voiceCommandService.persistentConversationMode = true
                        if !voiceCommandService.isListening {
                            try? voiceCommandService.startListening()
                        }
                        voiceCommandService.enterConversationMode()
''',
    "viewmodel persistent text conversation start",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func stopDirectGeminiVoiceMode() {
        directGeminiTimeoutTask?.cancel()
        directGeminiTimeoutTask = nil
        guard isDirectGeminiVoiceMode || audioCapture.isCapturing else { return }
''',
    '''    private func stopDirectGeminiVoiceMode() {
        directGeminiTimeoutTask?.cancel()
        directGeminiTimeoutTask = nil
        directGeminiResponseWatchdogTask?.cancel()
        directGeminiResponseWatchdogTask = nil
        guard isDirectGeminiVoiceMode || audioCapture.isCapturing else { return }
''',
    "viewmodel stop response watchdog",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func armDirectGeminiConversationTimeout() {
        directGeminiTimeoutTask?.cancel()
        directGeminiTimeoutTask = nil
        let timeout = settingsManager.settings.conversationTimeout
        guard timeout > 0, isDirectGeminiVoiceMode, isSessionActive else { return }

        directGeminiTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.isDirectGeminiVoiceMode, self.isSessionActive else { return }
            if self.geminiLive.isModelSpeaking || self.geminiLive.isProcessing {
                self.armDirectGeminiConversationTimeout()
                return
            }
            DiagnosticLogger.shared.log("Voice", "Direct Gemini conversation timeout fired")
            self.stopSession()
        }
        DiagnosticLogger.shared.log("Voice", "Direct Gemini conversation auto-end armed for \\(Int(timeout))s")
    }
''',
    '''    private func armDirectGeminiConversationTimeout() {
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
                self.recoverDirectConversationToWake(reason: "Gemini recovery failed: \\(error.localizedDescription)")
            }
        }
    }

    private func recoverDirectConversationToWake(reason: String) {
        guard isDirectGeminiVoiceMode || voiceCommandService.isWakeRecoverySuppressed else { return }
        DiagnosticLogger.shared.log("Voice", "Conversation runtime recovering to wake listener: \\(reason)")
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
''',
    "viewmodel persistent direct conversation + watchdog",
)

# Explicitly clear persistence when a session is intentionally stopped.
viewmodel = replace_once(
    viewmodel,
    '''    func stopSession() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
''',
    '''    func stopSession() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        voiceCommandService.persistentConversationMode = false
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
''',
    "viewmodel stop persistence",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func performFullStop() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
''',
    '''    private func performFullStop() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        voiceCommandService.persistentConversationMode = false
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
''',
    "viewmodel full stop persistence",
)

# Active text sessions no longer close on a 30s silence pulse.
viewmodel = replace_once(
    viewmodel,
    '''        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = { [weak self] in
            guard let self else { return }
            // In live video mode, silence must not end the session — the .idle state handler
            // re-arms conversation mode so the user can keep asking until they say "stop video".
            if self.isLiveVideoMode {
                print("[VoiceAgent] Conversation timeout during live video — staying live")
                return
            }
            print("[VoiceAgent] Conversation timeout - returning to idle")
            self.stopSession()
        }
''',
    '''        // Idle pulse inside an already-open conversation. The service itself re-arms the
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
''',
    "viewmodel persistent conversation idle callback",
)

# Gemini input/output/tool/interruption/recovery callbacks.
viewmodel = replace_once(
    viewmodel,
    '''        GeminiLiveService.shared.onInputTranscription = { [weak self] (text: String) in
            guard let self, self.isDirectGeminiVoiceMode else { return }
            self.directGeminiTimeoutTask?.cancel()
            self.directGeminiTimeoutTask = nil
            if self.directGeminiAwaitingNewInput {
                self.userTranscript = ""
                self.aiTranscript = ""
                self.historyLastLiveReply = ""
                self.directGeminiAwaitingNewInput = false
            }
            self.userTranscript += text
        }

        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
            guard let self else { return }
            // Gemini sends outputAudioTranscription incrementally (often word/phrase fragments).
            // Preserve the full reply for the live UI and persisted History.
            self.aiTranscript += text
        }

        GeminiLiveService.shared.onTurnComplete = { [weak self] in
''',
    '''        GeminiLiveService.shared.onInputTranscription = { [weak self] (text: String) in
            guard let self, self.isDirectGeminiVoiceMode else { return }
            if self.directGeminiAwaitingNewInput {
                self.userTranscript = ""
                self.aiTranscript = ""
                self.historyLastLiveReply = ""
                self.directGeminiAwaitingNewInput = false
            }
            self.userTranscript += text
            self.agentState = .listening
            self.armDirectGeminiResponseWatchdog()
        }

        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
            guard let self else { return }
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
''',
    "viewmodel gemini runtime callbacks",
)

viewmodel = replace_once(
    viewmodel,
    '''        GeminiLiveService.shared.onTurnComplete = { [weak self] in
            guard let self else { return }
            // A response that was explicitly stopped can still deliver a late server boundary.
''',
    '''        GeminiLiveService.shared.onTurnComplete = { [weak self] in
            guard let self else { return }
            self.directGeminiResponseWatchdogTask?.cancel()
            self.directGeminiResponseWatchdogTask = nil
            // A response that was explicitly stopped can still deliver a late server boundary.
''',
    "viewmodel turn complete cancels watchdog",
)


assert 'CURRENT_PROJECT_VERSION: "32"' in project, "Build number is not 32"
project = project.replace('CURRENT_PROJECT_VERSION: "32"', 'CURRENT_PROJECT_VERSION: "33"', 1)

notes += '''\n\n## Build 33 — Conversation Runtime v2\n- Reworks voice lifecycle around a persistent conversation session inspired by ChatGPT Live / realtime-agent patterns.\n- One wake word opens the session; follow-up turns no longer require another wake after idle periods.\n- Direct Gemini voice no longer auto-ends after the per-turn conversation timeout.\n- Text backends (including OpenClaw) keep Apple STT conversation mode alive through idle pulses.\n- Gemini interruptions keep the same full-duplex session alive and reset turn bookkeeping instead of tearing down audio.\n- Gemini native tool calls expose a real tool-running state and execute inside the same live session.\n- Adds a 15-second silent-turn watchdog: reconnect with session resumption and replay the last transcript once if Gemini becomes silent.\n- If bounded Gemini recovery is exhausted, microphone ownership is atomically returned to the local wake listener so “Ok Jarvis” works again.\n'''

voice_path.write_text(voice, encoding="utf-8")
viewmodel_path.write_text(viewmodel, encoding="utf-8")
gemini_path.write_text(gemini, encoding="utf-8")
project_path.write_text(project, encoding="utf-8")
notes_path.write_text(notes, encoding="utf-8")

subprocess.run(["git", "diff", "--check"], check=True)
subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
subprocess.run([
    "git", "add",
    str(voice_path), str(viewmodel_path), str(gemini_path), str(project_path), str(notes_path),
], check=True)
subprocess.run([
    "git", "commit", "-m",
    "Build 33: introduce persistent conversation runtime v2",
], check=True)
subprocess.run(["git", "push", "origin", "HEAD:jarvis-dev"], check=True)
