from pathlib import Path
import subprocess

voice_path = Path("JARVIS/Services/Voice/VoiceCommandService.swift")
capture_path = Path("JARVIS/Services/Audio/AudioCaptureService.swift")
gemini_path = Path("JARVIS/Services/GeminiLive/GeminiLiveService.swift")
openclaw_path = Path("JARVIS/Services/OpenClaw/OpenClawService.swift")
viewmodel_path = Path("JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift")
project_path = Path("project.yml")

voice = voice_path.read_text(encoding="utf-8")
capture = capture_path.read_text(encoding="utf-8")
gemini = gemini_path.read_text(encoding="utf-8")
openclaw = openclaw_path.read_text(encoding="utf-8")
viewmodel = viewmodel_path.read_text(encoding="utf-8")
project = project_path.read_text(encoding="utf-8")


def replace_once(text, old, new, label):
    assert old in text, f"{label} anchor changed"
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# VoiceCommandService: crash hardening around Objective-C audio APIs.
# ---------------------------------------------------------------------------
voice = replace_once(
    voice,
    '''    private func setupSpeechDetector() {
        speechDetector.onSpeechStart = { [weak self] in
''',
    '''    /// Some AVAudio/Speech calls raise Objective-C NSException instead of Swift Error.
    /// Rapid recognizer restarts can otherwise terminate the process with SIGABRT.
    private func removeTapSafely(from inputNode: AVAudioInputNode, context: String) {
        if let reason = OVCatchException({
            inputNode.removeTap(onBus: 0)
        }) {
            DiagnosticLogger.shared.log("Voice", "removeTap ignored [\\(context)]: \\(reason)")
        }
    }

    private nonisolated func appendSafely(
        _ buffer: AVAudioPCMBuffer,
        to request: SFSpeechAudioBufferRecognitionRequest
    ) {
        if let reason = OVCatchException({
            request.append(buffer)
        }) {
            DiagnosticLogger.shared.log("Voice", "Speech append exception suppressed: \\(reason)")
        }
    }

    private func setupSpeechDetector() {
        speechDetector.onSpeechStart = { [weak self] in
''',
    "voice safe helpers",
)

voice = replace_once(
    voice,
    '''        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
''',
    '''        removeTapSafely(from: inputNode, context: "startListening preinstall")
        let recordingFormat = inputNode.outputFormat(forBus: 0)
''',
    "voice start removeTap",
)

voice = replace_once(
    voice,
    '''            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
''',
    '''            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.appendSafely(buffer, to: recognitionRequest)
                detector.feed(buffer)
            }
''',
    "voice initial append",
)

voice = replace_once(
    voice,
    '''            audioEngine.inputNode.removeTap(onBus: 0)
            self.recognitionRequest = nil
''',
    '''            removeTapSafely(from: audioEngine.inputNode, context: "startListening start failure")
            self.recognitionRequest = nil
''',
    "voice start failure removeTap",
)

voice = replace_once(
    voice,
    '''        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
''',
    '''        if let inputNode = audioEngine?.inputNode {
            removeTapSafely(from: inputNode, context: "stopListening")
        }
        audioEngine?.stop()
''',
    "voice stop removeTap",
)

voice = replace_once(
    voice,
    '''    private func restartRecognition() {
        guard isListening else { return }

        recognitionGeneration += 1
''',
    '''    private func restartRecognition() {
        guard isListening else { return }

        // Count every direct restart too. Previously a scheduled recognizer restart could fire
        // immediately after a state-driven restart and churn the audio tap twice.
        lastRecognizerRestart = Date()

        recognitionGeneration += 1
''',
    "voice restart timestamp",
)

voice = replace_once(
    voice,
    '''        audioEngine?.inputNode.removeTap(onBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
''',
    '''        if let inputNode = audioEngine?.inputNode {
            removeTapSafely(from: inputNode, context: "restartRecognition teardown")
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
''',
    "voice restart removeTap",
)

voice = replace_once(
    voice,
    '''        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
''',
    '''        let inputNode = audioEngine.inputNode
        // The old restart path removed the same tap twice. The safe teardown above is enough.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
''',
    "voice duplicate removeTap",
)

voice = replace_once(
    voice,
    '''            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
''',
    '''            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.appendSafely(buffer, to: recognitionRequest)
                detector.feed(buffer)
            }
''',
    "voice restart append",
)


# ---------------------------------------------------------------------------
# AudioCaptureService: AEC + exception-safe tap for true full-duplex Gemini.
# ---------------------------------------------------------------------------
capture = replace_once(
    capture,
    '''        // Get native format
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioCapture] Native format: \\(nativeFormat)")

        // Install tap in native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, nativeFormat: nativeFormat)
        }

        try engine.start()
''',
    '''        // Voice-processing input keeps speaker echo out of the continuous Gemini stream.
        if AudioSessionManager.shared.isUsingBuiltInMic {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: ObjCBool(true),
                        duckingLevel: .min
                    )
                DiagnosticLogger.shared.log("Audio", "Direct stream voice processing enabled (AEC)")
            } catch {
                DiagnosticLogger.shared.log("Audio", "Direct stream AEC unavailable: \\(error.localizedDescription)")
            }
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioCapture] Native format: \\(nativeFormat)")

        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, nativeFormat: nativeFormat)
            }
        }) {
            self.audioEngine = nil
            self.inputNode = nil
            throw AudioCaptureError.tapInstallationFailed(reason)
        }

        try engine.start()
''',
    "capture AEC/tap",
)

capture = replace_once(
    capture,
    '''        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
''',
    '''        if let inputNode {
            if let reason = OVCatchException({
                inputNode.removeTap(onBus: 0)
            }) {
                DiagnosticLogger.shared.log("Audio", "Direct stream removeTap ignored: \\(reason)")
            }
        }
        audioEngine?.stop()
''',
    "capture safe removeTap",
)

capture = replace_once(
    capture,
    '''enum AudioCaptureError: LocalizedError {
    case engineCreationFailed
    case inputNodeUnavailable

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input node unavailable"
        }
    }
}
''',
    '''enum AudioCaptureError: LocalizedError {
    case engineCreationFailed
    case inputNodeUnavailable
    case tapInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input node unavailable"
        case .tapInstallationFailed(let reason): return "Failed to install audio capture tap: \\(reason)"
        }
    }
}
''',
    "capture error enum",
)


# ---------------------------------------------------------------------------
# Gemini Live: keep microphone audio flowing while model audio is playing.
# ---------------------------------------------------------------------------
gemini = replace_once(
    gemini,
    '''    func sendAudio(data: Data) {
        guard connectionState.isUsable, !isModelSpeaking else { return }
''',
    '''    func sendAudio(data: Data) {
        // Full duplex: server VAD needs microphone PCM even while the model is speaking so the
        // user can interrupt naturally. `interrupted` already clears queued local playback.
        guard connectionState.isUsable else { return }
''',
    "gemini full duplex",
)


# ---------------------------------------------------------------------------
# OpenClaw: partial-response streaming, watchdog, and friendly provider errors.
# ---------------------------------------------------------------------------
openclaw = replace_once(
    openclaw,
    '''    var onAgentMessage: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?
''',
    '''    var onAgentMessage: ((String) -> Void)?
    /// Cumulative assistant text as it arrives, used for sentence-level streaming speech.
    var onPartialResponse: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?
''',
    "openclaw partial callback",
)

openclaw = replace_once(
    openclaw,
    '''    private var accumulatedResponse = ""
    /// Run id returned by chat.send. Used to abort exactly the in-flight OpenClaw turn.
    private var activeRunId: String?

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
''',
    '''    private var accumulatedResponse = ""
    /// Run id returned by chat.send. Used to abort exactly the in-flight OpenClaw turn.
    private var activeRunId: String?

    private enum PartialResponseSource { case agent, chat }
    private var partialResponseSource: PartialResponseSource?
    private var turnWatchdogTask: Task<Void, Never>?

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
''',
    "openclaw stream state",
)

openclaw = replace_once(
    openclaw,
    '''        isProcessing = true
        accumulatedResponse = ""
        onProcessingChanged?(true)
''',
    '''        isProcessing = true
        accumulatedResponse = ""
        partialResponseSource = nil
        turnWatchdogTask?.cancel()
        onProcessingChanged?(true)
''',
    "openclaw turn reset",
)

openclaw = replace_once(
    openclaw,
    '''        activeRunId = response.payload?["runId"]?.stringValue
    }

    func cancelRequest() {
''',
    '''        activeRunId = response.payload?["runId"]?.stringValue
        startTurnWatchdog()
    }

    func cancelRequest() {
''',
    "openclaw watchdog start",
)

openclaw = replace_once(
    openclaw,
    '''    private func abortCurrentTurn() async {
        guard connectionState.isUsable else { return }
''',
    '''    private func abortCurrentTurn() async {
        turnWatchdogTask?.cancel()
        turnWatchdogTask = nil
        guard connectionState.isUsable else { return }
''',
    "openclaw abort watchdog",
)

openclaw = replace_once(
    openclaw,
    '''        accumulatedResponse = ""
        onProcessingChanged?(false)
        onToolStatusChanged?(nil, false)
    }

    func sendToolResult(callId: String, result: String) async throws {
''',
    '''        accumulatedResponse = ""
        partialResponseSource = nil
        onProcessingChanged?(false)
        onToolStatusChanged?(nil, false)
    }

    private func startTurnWatchdog() {
        turnWatchdogTask?.cancel()
        turnWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 18_000_000_000)
            } catch {
                return
            }
            guard let self, self.isProcessing else { return }
            let friendly = "O OpenClaw demorou demais para começar a responder. Interrompi esta tentativa para a conversa não ficar travada."
            self.lastError = friendly
            self.debugInfo = "OpenClaw first-response timeout"
            DiagnosticLogger.shared.log("OpenClaw", "First response timeout after 18s; aborting turn")
            await self.abortCurrentTurn()
            self.onAgentMessage?(friendly)
        }
    }

    private func noteTurnProgress() {
        turnWatchdogTask?.cancel()
        turnWatchdogTask = nil
    }

    private func appendPartial(_ text: String, source: PartialResponseSource) {
        guard !text.isEmpty else { return }
        noteTurnProgress()
        if partialResponseSource == nil { partialResponseSource = source }
        guard partialResponseSource == source else { return }
        accumulatedResponse += text
        onPartialResponse?(accumulatedResponse)
    }

    private func friendlyErrorMessage(for raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("429") || lower.contains("quota") || lower.contains("rate limit") {
            return "O OpenClaw atingiu o limite da IA configurada no computador. A conexão está funcionando, mas o provedor do OpenClaw precisa de cota disponível."
        }
        if lower.contains("session file changed while embedded prompt lock was released") {
            Self.sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
            debugInfo = "Recovered from OpenClaw session takeover race"
            return "Houve um conflito interno de sessão no OpenClaw. A sessão já foi reiniciada; repita o comando."
        }
        return "O OpenClaw encontrou um erro ao responder. Tente novamente."
    }

    func sendToolResult(callId: String, result: String) async throws {
''',
    "openclaw helpers",
)

openclaw = replace_once(
    openclaw,
    '''            if stream == "assistant", let text = data["text"] as? String, !text.isEmpty {
                accumulatedResponse += text
            } else if stream == "tool" {
''',
    '''            if stream == "assistant", let text = data["text"] as? String, !text.isEmpty {
                appendPartial(text, source: .agent)
            } else if stream == "tool" {
                noteTurnProgress()
''',
    "openclaw agent delta",
)

openclaw = replace_once(
    openclaw,
    '''            case "delta":
                appendTextBlocks(from: payload)
            case "final":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                let finalText = textBlocks(from: payload)
                let responseText = finalText.isEmpty ? accumulatedResponse : finalText
                accumulatedResponse = ""
                if !responseText.isEmpty { onAgentMessage?(responseText) }
            case "error":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                let message = payload["errorMessage"]?.stringValue ?? "OpenClaw error"
                accumulatedResponse = ""
                if message.localizedCaseInsensitiveContains("session file changed while embedded prompt lock was released") {
                    // Known OpenClaw 2026.7.1 session-fence race. Do not read a Windows file path
                    // aloud; rotate the JARVIS session so the very next command starts cleanly.
                    Self.sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
                    let friendly = "Houve um conflito interno de sessão no OpenClaw. A sessão já foi reiniciada; repita o comando."
                    lastError = friendly
                    debugInfo = "Recovered from OpenClaw session takeover race"
                    onAgentMessage?(friendly)
                } else {
                    lastError = message
                    onAgentMessage?("OpenClaw error: \\(message)")
                }
            case "aborted":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                accumulatedResponse = ""
''',
    '''            case "delta":
                let text = textBlocks(from: payload)
                if !text.isEmpty { appendPartial(text, source: .chat) }
            case "final":
                turnWatchdogTask?.cancel()
                turnWatchdogTask = nil
                activeRunId = nil
                isProcessing = false
                let finalText = textBlocks(from: payload)
                let responseText = finalText.isEmpty ? accumulatedResponse : finalText
                if !responseText.isEmpty { onAgentMessage?(responseText) }
                accumulatedResponse = ""
                partialResponseSource = nil
                // Flush the final streamed utterance before VoiceAgent observes processing=false.
                onProcessingChanged?(false)
            case "error":
                turnWatchdogTask?.cancel()
                turnWatchdogTask = nil
                activeRunId = nil
                isProcessing = false
                let message = payload["errorMessage"]?.stringValue ?? "OpenClaw error"
                let friendly = friendlyErrorMessage(for: message)
                lastError = friendly
                DiagnosticLogger.shared.log("OpenClaw", "Provider error suppressed: \\(message)")
                accumulatedResponse = ""
                partialResponseSource = nil
                onAgentMessage?(friendly)
                onProcessingChanged?(false)
            case "aborted":
                turnWatchdogTask?.cancel()
                turnWatchdogTask = nil
                activeRunId = nil
                isProcessing = false
                accumulatedResponse = ""
                partialResponseSource = nil
                onProcessingChanged?(false)
''',
    "openclaw chat events",
)


# ---------------------------------------------------------------------------
# VoiceAgentViewModel: direct Gemini PCM mode and OpenClaw streaming voice.
# ---------------------------------------------------------------------------
viewmodel = replace_once(
    viewmodel,
    '''    let ttsService = TTSService.shared
    let soundService = SoundService.shared
''',
    '''    let ttsService = TTSService.shared
    let geminiStreamingTTS = GeminiStreamingTTSService.shared
    let soundService = SoundService.shared
''',
    "viewmodel tts dependency",
)

viewmodel = replace_once(
    viewmodel,
    '''    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
''',
    '''    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false

    private var isDirectGeminiVoiceMode = false
    private var directGeminiAwaitingNewInput = true
    private var directGeminiTimeoutTask: Task<Void, Never>?

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
''',
    "viewmodel direct state",
)

viewmodel = replace_once(
    viewmodel,
    '''            return self.ttsService.isSpeaking
                || KokoroTTSService.shared.isSpeaking
''',
    '''            return self.ttsService.isSpeaking
                || self.geminiStreamingTTS.isSpeaking
                || KokoroTTSService.shared.isSpeaking
''',
    "viewmodel interrupt cloud voice",
)

# Stop the new output path anywhere existing speech is force-stopped.
viewmodel = viewmodel.replace(
    '''self.ttsService.stop()
                self.ttsStreaming = false''',
    '''self.ttsService.stop()
                self.geminiStreamingTTS.stop()
                self.ttsStreaming = false''',
)
viewmodel = viewmodel.replace(
    '''self.ttsService.stop()
            KokoroTTSService.shared.stop()''',
    '''self.ttsService.stop()
            self.geminiStreamingTTS.stop()
            KokoroTTSService.shared.stop()''',
)
viewmodel = viewmodel.replace(
    '''ttsService.stop()
        KokoroTTSService.shared.stop()''',
    '''ttsService.stop()
        geminiStreamingTTS.stop()
        KokoroTTSService.shared.stop()''',
)

viewmodel = replace_once(
    viewmodel,
    '''                // Start voice command listening for speech capture
                if voiceCommandService.authorizationStatus == .authorized {
                    if !voiceCommandService.isListening {
                        try? voiceCommandService.startListening()
                    }
                    // Put in listening mode (not waiting for wake word)
                    voiceCommandService.enterConversationMode()
                } else {
                    errorMessage = "Speech recognition not authorized"
                }
''',
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
                    } else {
                        errorMessage = "Speech recognition not authorized"
                    }
                }
''',
    "viewmodel start direct gemini",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func resumeListeningAfterSpeaking() {
        voiceCommandService.enterConversationMode()
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
''',
    '''    private func resumeListeningAfterSpeaking() {
        if isDirectGeminiVoiceMode {
            armDirectGeminiConversationTimeout()
        } else {
            voiceCommandService.enterConversationMode()
        }
    }

    private func startDirectGeminiVoiceMode() throws {
        directGeminiTimeoutTask?.cancel()
        directGeminiAwaitingNewInput = true

        if voiceCommandService.isListening {
            voiceCommandService.stopListening()
        }

        audioCapture.onAudioCaptured = { [weak self] data in
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
        guard isDirectGeminiVoiceMode || audioCapture.isCapturing else { return }
        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil
        isDirectGeminiVoiceMode = false
        directGeminiAwaitingNewInput = true
        DiagnosticLogger.shared.log("Gemini", "Direct microphone PCM streaming stopped")
    }

    private func armDirectGeminiConversationTimeout() {
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

    private var shouldUseGeminiStreamingVoiceForOpenClaw: Bool {
        settingsManager.settings.aiBackend == .openClaw
            && !settingsManager.settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginActiveStreamingTTS() {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.beginStreaming()
        } else {
            ttsService.beginStreaming()
        }
    }

    private func speakActiveStreamingChunk(_ text: String) {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.speakChunk(text)
        } else {
            ttsService.speakChunk(text)
        }
    }

    private func endActiveStreamingTTS() {
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            geminiStreamingTTS.endStreaming()
        } else {
            ttsService.endStreaming()
        }
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
''',
    "viewmodel direct helpers",
)

viewmodel = replace_once(
    viewmodel,
    '''    func stopSession() {
        // If in live video mode, stop it first
''',
    '''    func stopSession() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }

        // If in live video mode, stop it first
''',
    "viewmodel stop direct",
)

viewmodel = replace_once(
    viewmodel,
    '''        if settingsManager.settings.wakeWordEnabled {
            // Exit conversation mode but keep listening for wake word
            voiceCommandService.exitConversationMode()
        } else {
''',
    '''        if settingsManager.settings.wakeWordEnabled {
            if wasDirectGeminiVoice {
                if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
                    startWakeWordListening()
                }
            } else {
                voiceCommandService.exitConversationMode()
            }
        } else {
''',
    "viewmodel wake restore",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func performFullStop() {
        ttsService.stop()
''',
    '''    private func performFullStop() {
        let wasDirectGeminiVoice = isDirectGeminiVoiceMode
        if wasDirectGeminiVoice { stopDirectGeminiVoiceMode() }
        ttsService.stop()
''',
    "viewmodel full stop direct",
)

viewmodel = replace_once(
    viewmodel,
    '''        isSessionActive = false
        agentState = .idle
    }

    // MARK: - Voice Command Setup
''',
    '''        isSessionActive = false
        agentState = .idle

        if wasDirectGeminiVoice,
           settingsManager.settings.wakeWordEnabled,
           voiceCommandService.authorizationStatus == .authorized,
           !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    // MARK: - Voice Command Setup
''',
    "viewmodel full stop wake restore",
)

viewmodel = replace_once(
    viewmodel,
    '''        // OpenClaw extras: tool status + device-side tool calls.
        OpenClawService.shared.onToolStatusChanged = { [weak self] (toolName: String?, isRunning: Bool) in
''',
    '''        // OpenClaw partial text is a cumulative snapshot. Speak completed sentences while
        // generation is still running instead of waiting for the final response.
        OpenClawService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self, self.isSessionActive else { return }
            self.aiTranscript = partial
            self.feedStreamingSpeech(partial, isFinal: false)
        }

        geminiStreamingTTS.onSpeechStarted = { [weak self] in
            guard let self else { return }
            self.agentState = .speaking
            self.voiceCommandService.isBargeInPaused = true
        }
        geminiStreamingTTS.onSpeechEnded = { [weak self] in
            guard let self else { return }
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
''',
    "viewmodel openclaw partial",
)

viewmodel = replace_once(
    viewmodel,
    '''        // Gemini Live callbacks (for Gemini Live mode, not hybrid)
        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
''',
    '''        // Gemini Live callbacks. Normal voice also uses them in direct PCM mode.
        GeminiLiveService.shared.onInputTranscription = { [weak self] (text: String) in
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
''',
    "viewmodel gemini input transcript",
)

viewmodel = replace_once(
    viewmodel,
    '''            self.agentState = self.isLiveVideoMode ? .liveVideo : .listening
            self.voiceCommandService.enterConversationMode()
            // History: persist this Gemini Live exchange (transcript only, no frames).
            self.recordLiveTurn()
''',
    '''            self.agentState = self.isLiveVideoMode ? .liveVideo : .listening
            // History: persist this Gemini Live exchange (transcript only, no frames).
            self.recordLiveTurn()
            if self.isDirectGeminiVoiceMode {
                self.directGeminiAwaitingNewInput = true
                self.armDirectGeminiConversationTimeout()
            } else {
                self.voiceCommandService.enterConversationMode()
            }
''',
    "viewmodel gemini turn complete",
)

viewmodel = replace_once(
    viewmodel,
    '''            ttsStreaming = true
            ttsStreamSpokenChars = 0
            ttsService.beginStreaming()
''',
    '''            ttsStreaming = true
            ttsStreamSpokenChars = 0
            beginActiveStreamingTTS()
''',
    "viewmodel streaming begin",
)

viewmodel = replace_once(
    viewmodel,
    '''            if !tail.isEmpty { ttsService.speakChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            ttsService.endStreaming()
''',
    '''            if !tail.isEmpty { speakActiveStreamingChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            endActiveStreamingTTS()
''',
    "viewmodel streaming final",
)

viewmodel = replace_once(
    viewmodel,
    '''        ttsService.speakChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
''',
    '''        speakActiveStreamingChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
''',
    "viewmodel streaming sentence",
)

viewmodel = replace_once(
    viewmodel,
    '''        recordAssistantReply(text)
        // Kokoro (on-device neural) when selected + ready; otherwise the Apple system voice.
        if settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady {
            Task { await KokoroTTSService.shared.speak(text, voice: settingsManager.settings.kokoroVoice) }
        } else {
            ttsService.speak(text)
        }
''',
    '''        recordAssistantReply(text)
        if shouldUseGeminiStreamingVoiceForOpenClaw {
            // Same configured Google voice as Gemini Live (Charon by default).
            geminiStreamingTTS.speak(text)
        } else if settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady {
            Task { await KokoroTTSService.shared.speak(text, voice: settingsManager.settings.kokoroVoice) }
        } else {
            ttsService.speak(text)
        }
''',
    "viewmodel single response voice",
)

viewmodel = replace_once(
    viewmodel,
    '''                    if self.ttsStreaming {
                        self.ttsService.endStreaming()
                        self.ttsStreaming = false
                    }
''',
    '''                    if self.ttsStreaming {
                        self.endActiveStreamingTTS()
                        self.ttsStreaming = false
                    }
''',
    "viewmodel processing stream cleanup",
)


assert 'CURRENT_PROJECT_VERSION: "30"' in project, "Build number is not 30"
project = project.replace('CURRENT_PROJECT_VERSION: "30"', 'CURRENT_PROJECT_VERSION: "31"', 1)

voice_path.write_text(voice, encoding="utf-8")
capture_path.write_text(capture, encoding="utf-8")
gemini_path.write_text(gemini, encoding="utf-8")
openclaw_path.write_text(openclaw, encoding="utf-8")
viewmodel_path.write_text(viewmodel, encoding="utf-8")
project_path.write_text(project, encoding="utf-8")

subprocess.run(["git", "diff", "--check"], check=True)
subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
subprocess.run([
    "git", "add",
    str(voice_path), str(capture_path), str(gemini_path),
    str(openclaw_path), str(viewmodel_path), str(project_path),
], check=True)
subprocess.run([
    "git", "commit", "-m",
    "Build 31: stabilize voice runtime and add full-duplex streaming",
], check=True)
subprocess.run(["git", "push", "origin", "HEAD:jarvis-dev"], check=True)
