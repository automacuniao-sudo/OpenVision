from pathlib import Path


def replace(path: str, old: str, new: str):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"Pattern not found in {path}: {old[:220]!r}")
    p.write_text(text.replace(old, new, 1))

# -----------------------------------------------------------------------------
# 1) Adaptive pt-BR end-of-turn detection.
# -----------------------------------------------------------------------------
replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''    /// Tracks if user has started speaking in this turn\n    private var hasSpokenThisTurn: Bool = false\n''',
    '''    /// Tracks if user has started speaking in this turn\n    private var hasSpokenThisTurn: Bool = false\n\n    /// Timestamp of the most recent non-empty Apple Speech partial for the active command. Used\n    /// to measure the real local endpointing delay (last STT update -> command dispatch).\n    private var lastSpeechRecognitionUpdateAt: Date?\n'''
)

replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''            currentTranscription = command\n\n            // Mark that user has started speaking\n            if command.count > 3 {\n''',
    '''            currentTranscription = command\n            if !command.isEmpty {\n                lastSpeechRecognitionUpdateAt = Date()\n            }\n\n            // Mark that user has started speaking\n            if command.count > 3 {\n'''
)

replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''        print("[VoiceCommand] Command captured: \\(command)")\n        DiagnosticLogger.shared.log("Voice", "Command captured: \\(command)")\n\n        state = .processing\n''',
    '''        if let lastUpdate = lastSpeechRecognitionUpdateAt {\n            let endpointMs = Int(Date().timeIntervalSince(lastUpdate) * 1000)\n            let profile = TurnEndpointing.isLikelyComplete(command) ? "fast" : "grace"\n            DiagnosticLogger.shared.log("Latency", "STT last-partial→command=\\(endpointMs)ms profile=\\(profile)")\n        }\n        lastSpeechRecognitionUpdateAt = nil\n\n        print("[VoiceCommand] Command captured: \\(command)")\n        DiagnosticLogger.shared.log("Voice", "Command captured: \\(command)")\n\n        state = .processing\n'''
)

replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''    /// Reset silence timer\n    private func resetSilenceTimer() {\n        silenceTimer?.invalidate()\n        silenceTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.silenceTimeout, repeats: false) { [weak self] _ in\n            Task { @MainActor in\n                self?.handleSilenceTimeout()\n            }\n        }\n    }\n''',
    '''    /// Reset silence timer using Portuguese-aware adaptive endpointing. Complete-looking\n    /// phrases commit quickly; dangling phrases keep a generous window so natural pauses are not\n    /// cut off.\n    private func resetSilenceTimer() {\n        silenceTimer?.invalidate()\n        let timeout = TurnEndpointing.silenceTimeout(for: currentTranscription)\n        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in\n            Task { @MainActor in\n                self?.handleSilenceTimeout()\n            }\n        }\n    }\n'''
)

replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''        hasSpokenThisTurn = false\n        currentTranscription = ""\n\n        // Start conversation timeout (exits if no speech for 4 seconds)\n''',
    '''        hasSpokenThisTurn = false\n        currentTranscription = ""\n        lastSpeechRecognitionUpdateAt = nil\n\n        // Start conversation timeout (exits if no speech for the configured conversation window)\n'''
)

replace(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''        state = .listening\n        currentTranscription = ""\n        restartRecognition()\n''',
    '''        state = .listening\n        currentTranscription = ""\n        lastSpeechRecognitionUpdateAt = nil\n        restartRecognition()\n'''
)

# Constants: keep a documented fallback value only. VoiceCommandService no longer pays 4 seconds.
replace(
    "OpenVision/Config/Constants.swift",
    '''        /// Silence timeout to end command capture (seconds)\n        static let silenceTimeout: TimeInterval = 4.0\n''',
    '''        /// Legacy/fallback silence timeout. Normal voice turns use TurnEndpointing instead.\n        static let silenceTimeout: TimeInterval = 4.0\n'''
)

# -----------------------------------------------------------------------------
# 2) Gemini Live session resumption, GoAway handling and automatic recovery.
# -----------------------------------------------------------------------------
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    private var receiveTask: Task<Void, Never>?\n    private var isSetupComplete: Bool = false\n''',
    '''    private var receiveTask: Task<Void, Never>?\n    private var isSetupComplete: Bool = false\n\n    // MARK: - Session Resumption / Recovery\n\n    /// Latest resumable state handle supplied by Gemini Live. It is intentionally kept only in\n    /// memory and never written to Diagnostics. A normal user-ended conversation clears it; an\n    /// unexpected socket reset keeps it so the new WebSocket can resume the same session.\n    private var sessionResumptionHandle: String?\n    private var reconnectTask: Task<Void, Never>?\n    private var reconnectAfterTurn = false\n    private var intentionalDisconnect = false\n    private let maxReconnectAttempts = 4\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    // MARK: - Latency Tracking\n\n    private var lastUserSpeechEnd: Date?\n''',
    '''    // MARK: - Latency Tracking\n\n    private var lastUserSpeechEnd: Date?\n    private var currentTurnSentAt: Date?\n    private var firstPCMSeenForTurn = false\n    private var lastPCMReceivedAt: Date?\n    private var maxPCMGapMs: Double = 0\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    func connect() async throws {\n        guard !apiKey.isEmpty else {\n''',
    '''    func connect() async throws {\n        intentionalDisconnect = false\n\n        guard !apiKey.isEmpty else {\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        DiagnosticLogger.shared.log("Gemini", "Connecting model=\\(Constants.GeminiLive.modelName) voice=\\(voiceName)")\n''',
    '''        DiagnosticLogger.shared.log("Gemini", "Connecting model=\\(Constants.GeminiLive.modelName) voice=\\(voiceName) resume=\\(sessionResumptionHandle != nil)")\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''            connectionState = .connected\n            onConnectionStateChanged?(connectionState)\n            print("[GeminiLive] Connected")\n            DiagnosticLogger.shared.log("Gemini", "Connected and setup complete")\n''',
    '''            connectionState = .connected\n            onConnectionStateChanged?(connectionState)\n            print("[GeminiLive] Connected")\n            DiagnosticLogger.shared.log("Gemini", "Connected and setup complete resume=\\(sessionResumptionHandle != nil)")\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        print("[GeminiLive] Disconnecting")\n        DiagnosticLogger.shared.log("Gemini", "Disconnecting")\n        connectionState = .disconnected\n        onConnectionStateChanged?(connectionState)\n        closeWebSocket()\n''',
    '''        print("[GeminiLive] Disconnecting")\n        DiagnosticLogger.shared.log("Gemini", "Disconnecting (intentional)")\n        intentionalDisconnect = true\n        reconnectAfterTurn = false\n        reconnectTask?.cancel()\n        reconnectTask = nil\n        sessionResumptionHandle = nil\n        connectionState = .disconnected\n        onConnectionStateChanged?(connectionState)\n        closeWebSocket()\n'''
)

# Setup gets sessionResumption even for a fresh session (empty object), which makes Gemini send
# SessionResumptionUpdate events. On a reconnect, the latest handle is supplied.
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    private func sendSetup() async throws {\n        let setup: [String: Any] = [\n''',
    '''    private func sendSetup() async throws {\n        var resumption: [String: Any] = [:]\n        if let handle = sessionResumptionHandle {\n            resumption["handle"] = handle\n        }\n\n        let setup: [String: Any] = [\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''                "inputAudioTranscription": [:] as [String: Any],\n                "outputAudioTranscription": [:] as [String: Any],\n                "tools": buildToolDeclarations()\n''',
    '''                "inputAudioTranscription": [:] as [String: Any],\n                "outputAudioTranscription": [:] as [String: Any],\n                "sessionResumption": resumption,\n                "tools": buildToolDeclarations()\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS + native tools")\n''',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\\(voiceName) + pt-BR JARVIS + native tools + sessionResumption")\n'''
)

# Text turns recover synchronously if the socket died while connectionState still looked usable.
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    func sendText(_ text: String) async throws {\n        guard connectionState.isUsable else {\n            throw AIBackendError.notConnected\n        }\n        // Record the utterance for the tool registry's relative-time guard.\n''',
    '''    func sendText(_ text: String) async throws {\n        if !connectionState.isUsable {\n            try await reconnectImmediately(reason: "text turn while disconnected")\n        }\n\n        // Record the utterance for the tool registry's relative-time guard.\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        DiagnosticLogger.shared.log("Gemini", "Sending text turn: \\(text)")\n        try await sendJSON(message)\n    }\n''',
    '''        currentTurnSentAt = Date()\n        firstPCMSeenForTurn = false\n        lastPCMReceivedAt = nil\n        maxPCMGapMs = 0\n\n        DiagnosticLogger.shared.log("Gemini", "Sending text turn: \\(text)")\n        do {\n            try await sendJSON(message)\n        } catch {\n            DiagnosticLogger.shared.log("Gemini", "Text send failed; reconnecting once: \\(error.localizedDescription)")\n            try await reconnectImmediately(reason: "text send failure")\n            try await sendJSON(message)\n            DiagnosticLogger.shared.log("Gemini", "Text turn resent after reconnect")\n        }\n    }\n'''
)

# Receive errors now trigger recovery instead of leaving the active conversation on a dead socket.
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''                        DiagnosticLogger.shared.log("Gemini", "Receive error: \\(error.localizedDescription)")\n                        await self.handleDisconnect()\n''',
    '''                        DiagnosticLogger.shared.log("Gemini", "Receive error: \\(error.localizedDescription)")\n                        await self.handleDisconnect(reason: "receive error: \\(error.localizedDescription)")\n'''
)

# SessionResumptionUpdate handling (root-level event).
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        // Setup complete\n        if json["setupComplete"] != nil {\n''',
    '''        // Session resumption updates are sent only when sessionResumption was configured in\n        // setup. Keep the newest resumable handle so a replacement WebSocket can preserve context.\n        if let update = json["sessionResumptionUpdate"] as? [String: Any] {\n            let resumable = update["resumable"] as? Bool ?? false\n            if resumable, let handle = update["newHandle"] as? String, !handle.isEmpty {\n                sessionResumptionHandle = handle\n                DiagnosticLogger.shared.log("Gemini", "Session resumption handle updated (resumable=true)")\n            } else if !resumable {\n                DiagnosticLogger.shared.log("Gemini", "Session resumption update resumable=false")\n            }\n        }\n\n        // Setup complete\n        if json["setupComplete"] != nil {\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        // Go away (server closing connection)\n        if json["goAway"] != nil {\n            print("[GeminiLive] Server requested disconnect")\n            await handleDisconnect()\n            return\n        }\n''',
    '''        // GoAway is an advance warning that Gemini will close this WebSocket. If a response\n        // is currently generating, let it finish and reconnect immediately after the turn; otherwise\n        // replace the socket now using the latest resumable handle.\n        if let goAway = json["goAway"] as? [String: Any] {\n            let timeLeft = String(describing: goAway["timeLeft"] ?? "unknown")\n            DiagnosticLogger.shared.log("Gemini", "GoAway received timeLeft=\\(timeLeft)")\n            if isProcessing || isModelSpeaking {\n                reconnectAfterTurn = true\n                DiagnosticLogger.shared.log("Gemini", "GoAway recovery deferred until turn complete")\n            } else {\n                scheduleReconnect(reason: "GoAway timeLeft=\\(timeLeft)")\n            }\n            return\n        }\n'''
)

# Precise transport metrics for first PCM and packet gaps.
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''                    isModelSpeaking = true\n                    isProcessing = true\n                    DiagnosticLogger.shared.log("GeminiAudio", "Received PCM chunk bytes=\\(audioData.count)")\n''',
    '''                    let pcmNow = Date()\n                    if !firstPCMSeenForTurn, let sentAt = currentTurnSentAt {\n                        firstPCMSeenForTurn = true\n                        let firstMs = Int(pcmNow.timeIntervalSince(sentAt) * 1000)\n                        DiagnosticLogger.shared.log("Latency", "Gemini send→firstPCM=\\(firstMs)ms")\n                    }\n                    if let previousPCM = lastPCMReceivedAt {\n                        let gapMs = pcmNow.timeIntervalSince(previousPCM) * 1000\n                        maxPCMGapMs = max(maxPCMGapMs, gapMs)\n                        if gapMs >= 500 {\n                            DiagnosticLogger.shared.log("Latency", "Gemini PCM gap=\\(Int(gapMs))ms")\n                        }\n                    }\n                    lastPCMReceivedAt = pcmNow\n\n                    isModelSpeaking = true\n                    isProcessing = true\n                    DiagnosticLogger.shared.log("GeminiAudio", "Received PCM chunk bytes=\\(audioData.count)")\n'''
)

replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    private func finishTurn() {\n        pendingTurnComplete = false\n        isModelSpeaking = false\n        isProcessing = false\n        DiagnosticLogger.shared.log("Gemini", "Turn complete")\n        onTurnComplete?()\n    }\n''',
    '''    private func finishTurn() {\n        pendingTurnComplete = false\n        isModelSpeaking = false\n        isProcessing = false\n\n        if let sentAt = currentTurnSentAt {\n            let totalMs = Int(Date().timeIntervalSince(sentAt) * 1000)\n            DiagnosticLogger.shared.log("Latency", "Gemini send→turnComplete=\\(totalMs)ms maxPCMGap=\\(Int(maxPCMGapMs))ms")\n        }\n        currentTurnSentAt = nil\n        firstPCMSeenForTurn = false\n        lastPCMReceivedAt = nil\n        maxPCMGapMs = 0\n\n        DiagnosticLogger.shared.log("Gemini", "Turn complete")\n        onTurnComplete?()\n\n        if reconnectAfterTurn {\n            reconnectAfterTurn = false\n            scheduleReconnect(reason: "deferred GoAway after turn")\n        }\n    }\n'''
)

# Replace old terminal disconnect with automatic recovery helpers.
replace(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''    /// Handle disconnect\n    private func handleDisconnect() async {\n        connectionState = .disconnected\n        onConnectionStateChanged?(connectionState)\n        closeWebSocket()\n        onDisconnected?()\n    }\n}\n''',
    '''    /// Replace a dead socket synchronously when the current user turn needs to be sent now.\n    /// The latest session-resumption handle is preserved.\n    private func reconnectImmediately(reason: String) async throws {\n        guard !intentionalDisconnect else { throw AIBackendError.notConnected }\n        DiagnosticLogger.shared.log("Gemini", "Immediate reconnect: \\(reason) resume=\\(sessionResumptionHandle != nil)")\n        closeWebSocket()\n        connectionState = .disconnected\n        onConnectionStateChanged?(connectionState)\n        try await connect()\n    }\n\n    /// Schedule bounded reconnect attempts for receive failures and GoAway. The service keeps the\n    /// conversation alive instead of notifying the ViewModel that the backend is permanently gone\n    /// after the first transport hiccup.\n    private func scheduleReconnect(reason: String) {\n        guard !intentionalDisconnect else { return }\n        guard reconnectTask == nil else { return }\n\n        DiagnosticLogger.shared.log("Gemini", "Scheduling reconnect: \\(reason) resume=\\(sessionResumptionHandle != nil)")\n        closeWebSocket()\n        connectionState = .disconnected\n        onConnectionStateChanged?(connectionState)\n\n        reconnectTask = Task { [weak self] in\n            guard let self else { return }\n            var lastReconnectError: Error?\n\n            for attempt in 1...self.maxReconnectAttempts {\n                if Task.isCancelled || self.intentionalDisconnect {\n                    self.reconnectTask = nil\n                    return\n                }\n\n                if attempt > 1 {\n                    let delay = min(pow(2.0, Double(attempt - 2)), 4.0)\n                    DiagnosticLogger.shared.log("Gemini", "Reconnect backoff=\\(String(format: \"%.1f\", delay))s")\n                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))\n                }\n\n                guard !Task.isCancelled, !self.intentionalDisconnect else {\n                    self.reconnectTask = nil\n                    return\n                }\n\n                DiagnosticLogger.shared.log("Gemini", "Reconnect attempt \\(attempt)/\\(self.maxReconnectAttempts)")\n                self.closeWebSocket()\n                self.connectionState = .disconnected\n                self.onConnectionStateChanged?(self.connectionState)\n\n                do {\n                    try await self.connect()\n                    DiagnosticLogger.shared.log("Gemini", "Reconnect succeeded attempt=\\(attempt) resume=\\(self.sessionResumptionHandle != nil)")\n                    self.reconnectTask = nil\n                    return\n                } catch {\n                    lastReconnectError = error\n                    DiagnosticLogger.shared.log("Gemini", "Reconnect attempt \\(attempt) failed: \\(error.localizedDescription)")\n                }\n            }\n\n            self.reconnectTask = nil\n            let message = lastReconnectError?.localizedDescription ?? "reconnect failed"\n            self.lastError = message\n            self.connectionState = .failed(message)\n            self.onConnectionStateChanged?(self.connectionState)\n            DiagnosticLogger.shared.log("Gemini", "Reconnect exhausted: \\(message)")\n            self.onDisconnected?()\n        }\n    }\n\n    /// Handle an unexpected receive-side disconnect.\n    private func handleDisconnect(reason: String) async {\n        if intentionalDisconnect {\n            connectionState = .disconnected\n            onConnectionStateChanged?(connectionState)\n            closeWebSocket()\n            onDisconnected?()\n            return\n        }\n        scheduleReconnect(reason: reason)\n    }\n}\n'''
)

# -----------------------------------------------------------------------------
# 3) Version and build notes. Leave web search, audio gain/routing, AEC and barge-in untouched.
# -----------------------------------------------------------------------------
replace("project.yml", '    CURRENT_PROJECT_VERSION: "22"\n', '    CURRENT_PROJECT_VERSION: "23"\n')

notes = Path("JARVIS_BUILD_NOTES.md")
text = notes.read_text()
header = "# Projeto JARVIS build notes\n\n"
if not text.startswith(header):
    raise SystemExit("Unexpected build notes header")
entry = '''## Build 23\n\n- Latency: replaced the fixed 4.0-second voice endpoint delay with Brazilian-Portuguese adaptive endpointing (0.9s for complete-looking phrases, 3.0s grace for unfinished/filler fragments).\n- Diagnostics: logs local STT endpoint delay as `STT last-partial→command`, Gemini `send→firstPCM`, large PCM packet gaps, full turn duration, and maximum packet gap.\n- Gemini Live stability: enabled official session resumption and retains the latest resumable handle in memory across unexpected WebSocket replacements.\n- Gemini Live stability: handles `GoAway` proactively; reconnects immediately when idle or after the active response finishes.\n- Gemini Live stability: receive-side socket failures now use bounded exponential-backoff reconnect instead of leaving the conversation on a dead backend.\n- Gemini Live stability: text send failures reconnect once synchronously and resend the turn.\n- Intentional conversation shutdown still clears the resumption handle so a future `Ok Jarvis` starts a clean session.\n- Audio routing/gain, AEC, barge-in, wake chime, web search and tool behavior are intentionally unchanged in this build.\n- App build number is 23.\n\n'''
notes.write_text(header + entry + text[len(header):])

# Clean up this one-shot patch mechanism from the final product commit.
Path(".github/workflows/apply-build23-latency-stability.yml").unlink(missing_ok=True)
Path("scripts/apply_build23_latency_stability.py").unlink(missing_ok=True)
