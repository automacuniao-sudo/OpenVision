// OpenVision - VoiceCommandService.swift
// Wake word detection and voice command capture using Apple Speech Recognition

import Foundation
import Speech
import AVFoundation

/// Voice command service with wake word detection
///
/// Features:
/// - Wake word detection ("Ok Vision" / configured wake word)
/// - Command capture after wake word
/// - Acoustic VAD end-of-turn with adaptive timer fallback
/// - Conversation mode (follow-ups without wake word)
/// - Barge-in support, including while the backend is thinking
@MainActor
final class VoiceCommandService: ObservableObject {
    // MARK: - Singleton

    static let shared = VoiceCommandService()

    // MARK: - Published State

    @Published var state: ListeningState = .idle
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // MARK: - Listening State

    enum ListeningState: Equatable {
        case idle
        case listening
        case conversationMode
        case processing
    }

    // MARK: - Configuration

    var wakeWord: String {
        SettingsManager.shared.settings.wakeWord
    }

    var isWakeWordEnabled: Bool {
        SettingsManager.shared.settings.wakeWordEnabled
    }

    var playActivationSound: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    // MARK: - Callbacks

    var onWakeWordDetected: (() -> Void)?
    var onStopCommand: (() -> Void)?
    var onCommandCaptured: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    var onConversationTimeout: (() -> Void)?

    // MARK: - Barge-in Control

    /// True while reply audio is actually audible. During audible output interruption matching is
    /// deliberately conservative to reject speaker echo; while thinking silently, any new user
    /// utterance can replace the in-flight turn.
    var isBargeInPaused: Bool = false

    /// Returns true when the current backend can be interrupted (speaking OR processing/thinking).
    var shouldAllowInterrupt: (() -> Bool)?

    // MARK: - Speech Recognition

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var lastRecognizerRestart = Date.distantPast
    private var wakeWordRestartScheduled = false
    private let minRestartInterval: TimeInterval = 0.6

    // MARK: - Timers

    private var silenceTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var conversationTimeoutTimer: Timer?
    private var wakeWordCooldownActive: Bool = false

    // MARK: - Acoustic VAD

    /// Silero VAD via FluidAudio. When available, this is the primary end-of-turn signal.
    private let speechDetector = SpeechActivityDetector()
    private var vadCommitPending = false

    /// Tracks if user has started speaking in this turn.
    private var hasSpokenThisTurn: Bool = false

    /// Timestamp of the most recent non-empty Apple Speech partial for diagnostics.
    private var lastSpeechRecognitionUpdateAt: Date?

    // MARK: - Initialization

    private init() {
        setupSpeechDetector()
    }

    private func setupSpeechDetector() {
        speechDetector.onSpeechStart = { [weak self] in
            guard let self else { return }
            // A pause inside a sentence is not end-of-turn. Cancel any pending VAD commit.
            self.vadCommitPending = false
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
        }

        speechDetector.onSpeechEnd = { [weak self] in
            self?.handleSpeechEnded()
        }

        Task {
            await speechDetector.start()
        }
    }

    /// Real acoustic speech end. Silero already applies silence hysteresis, so only a very small
    /// grace is needed for Apple's final transcript partial to catch up with the audio stream.
    private func handleSpeechEnded() {
        guard state == .listening || state == .conversationMode else { return }
        guard hasSpokenThisTurn, !currentTranscription.isEmpty else { return }

        vadCommitPending = true
        DiagnosticLogger.shared.log(
            "VAD",
            "speechEnd -> commit in \(Int(Constants.Voice.vadCommitGrace * 1000))ms text=\(currentTranscription)"
        )

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.Voice.vadCommitGrace,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.vadCommitPending else { return }
                self.vadCommitPending = false
                self.handleSilenceTimeout()
            }
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self.authorizationStatus = status
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Start/Stop

    func startListening() throws {
        guard authorizationStatus == .authorized else {
            throw VoiceCommandError.notAuthorized
        }
        guard !isListening else { return }

        audioEngine = AVAudioEngine()
        guard let audioEngine else {
            throw VoiceCommandError.audioEngineUnavailable
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw VoiceCommandError.requestCreationFailed
        }
        configureRecognitionRequest(recognitionRequest)

        // On the built-in mic, enable Apple's voice-processing/AEC before the engine starts so
        // reply audio is removed from the microphone signal as much as iOS allows.
        let inputNode = audioEngine.inputNode
        if AudioSessionManager.shared.isUsingBuiltInMic {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: ObjCBool(true),
                        duckingLevel: .min
                    )
                DiagnosticLogger.shared.log("Audio", "Voice processing enabled (AEC); other-audio ducking=min")
                AudioSessionManager.shared.enforcePhoneSpeakerRoute()
            } catch {
                DiagnosticLogger.shared.log("Audio", "Voice processing unavailable: \(error.localizedDescription)")
                print("[VoiceCommand] Voice processing enable failed: \(error)")
            }
        }

        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable (format \(recordingFormat.sampleRate)Hz/\(recordingFormat.channelCount)ch)")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
        }) {
            print("[VoiceCommand] installTap failed: \(reason)")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[VoiceCommand] Failed to start audio engine: \(error)")
            audioEngine.inputNode.removeTap(onBus: 0)
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        isListening = true
        state = isWakeWordEnabled ? .idle : .listening
        print("[VoiceCommand] Started listening - audio engine running")
        DiagnosticLogger.shared.log(
            "Voice",
            "Recognizer started locale=pt-BR state=\(state) route=\(AudioSessionManager.shared.currentRouteDescription) vad=\(speechDetector.isAvailable)"
        )
    }

    private func configureRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        request.shouldReportPartialResults = true
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = state == .idle ? .search : .dictation
        var phrases = [
            "Ok Jarvis", "Okay Jarvis", "Hey Jarvis", "Jarvis",
            "Ok Vision", "Okay Vision", "Hey Vision", "Vision"
        ]
        if !wakeWord.isEmpty { phrases.insert(wakeWord, at: 0) }
        request.contextualStrings = phrases
    }

    private func restartIfRecognizerEnded(result: SFSpeechRecognitionResult?, error: Error?) {
        let ended = (error != nil) || (result?.isFinal ?? false)
        let needsAlwaysOnRecognizer = (state == .idle && isWakeWordEnabled) || state == .conversationMode
        guard ended, isListening, needsAlwaysOnRecognizer else { return }
        if let error {
            print("[VoiceCommand] Recognizer ended (\(error.localizedDescription)) — will relaunch listener")
        }
        scheduleWakeWordRestart()
    }

    private func scheduleWakeWordRestart() {
        guard !wakeWordRestartScheduled else { return }
        wakeWordRestartScheduled = true
        let delay = max(0, minRestartInterval - Date().timeIntervalSince(lastRecognizerRestart))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.wakeWordRestartScheduled = false
            let stillNeedsRecognizer = (self.state == .idle && self.isWakeWordEnabled)
                || self.state == .conversationMode
            guard self.isListening, stillNeedsRecognizer else { return }
            self.lastRecognizerRestart = Date()
            self.restartRecognition()
        }
    }

    func stopListening() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        speechDetector.reset()
        vadCommitPending = false

        silenceTimer?.invalidate()
        silenceTimer = nil
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil

        isListening = false
        state = .idle
        currentTranscription = ""
        hasSpokenThisTurn = false
        lastSpeechRecognitionUpdateAt = nil
        print("[VoiceCommand] Stopped listening")
    }

    func enterConversationMode() {
        state = .conversationMode
        vadCommitPending = false
        restartRecognition()

        hasSpokenThisTurn = false
        currentTranscription = ""
        lastSpeechRecognitionUpdateAt = nil
        startConversationTimeout()
        print("[VoiceCommand] Entered conversation mode")
    }

    private func restartRecognition() {
        guard isListening else { return }

        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        configureRecognitionRequest(recognitionRequest)

        guard let audioEngine else { return }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                print("[VoiceCommand] Engine had stopped (route change) — restarted in place")
            } catch {
                print("[VoiceCommand] Engine restart failed: \(error)")
            }
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable on reinstall — skipping tap")
            self.recognitionRequest = nil
            return
        }

        // The input format can change after phone <-> Bluetooth route transitions.
        speechDetector.reset()
        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
        }) {
            print("[VoiceCommand] installTap (reinstall) failed: \(reason)")
            self.recognitionRequest = nil
            return
        }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        print("[VoiceCommand] Restarted recognition (cleared buffer)")
    }

    func exitConversationMode() {
        state = isWakeWordEnabled ? .idle : .listening
        vadCommitPending = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil
        hasSpokenThisTurn = false
        restartRecognition()
        print("[VoiceCommand] Exited conversation mode")
    }

    private func startConversationTimeout() {
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil

        let timeout = SettingsManager.shared.settings.conversationTimeout
        if timeout <= 0 {
            DiagnosticLogger.shared.log("Voice", "Conversation auto-end disabled (Never)")
            return
        }

        DiagnosticLogger.shared.log("Voice", "Conversation auto-end armed for \(Int(timeout))s")
        conversationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleConversationTimeout()
            }
        }
    }

    private func handleConversationTimeout() {
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

    // MARK: - Recognition Handling

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isListening else {
            print("[VoiceCommand] Ignoring result - not listening")
            return
        }

        guard let result else {
            if let error {
                let errorMsg = error.localizedDescription
                if !errorMsg.contains("No speech detected") && !errorMsg.contains("canceled") {
                    print("[VoiceCommand] Recognition error: \(error)")
                }
            }
            return
        }

        let transcription = result.bestTranscription.formattedString
        print("[VoiceCommand] 🎤 heard(\(state)): \"\(transcription)\"")
        DiagnosticLogger.shared.log("STT", "heard[\(state)]: \(transcription)")

        switch state {
        case .idle:
            currentTranscription = transcription
            if detectWakeWord(in: transcription) {
                handleWakeWordDetected()
            }

        case .listening, .conversationMode:
            var command = transcription
            for ww in [
                wakeWord.lowercased(),
                "ok jarvis", "okay jarvis", "hey jarvis", "jarvis",
                "ok vision", "okay vision", "hey vision", "hi vision"
            ] {
                if let range = command.lowercased().range(of: ww) {
                    command = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            currentTranscription = command
            if !command.isEmpty {
                lastSpeechRecognitionUpdateAt = Date()
            }

            if command.count > 3 {
                hasSpokenThisTurn = true
                conversationTimeoutTimer?.invalidate()
            }

            // No-op when VAD is active; adaptive text endpointing remains the soft fallback.
            resetSilenceTimer()

            if result.isFinal && !command.isEmpty {
                handleCommandComplete(command)
            }

        case .processing:
            let allowInterrupt = shouldAllowInterrupt?() ?? false
            guard allowInterrupt else { return }

            if isStopPhrase(transcription) {
                print("[VoiceCommand] Stop phrase during processing/TTS — halting")
                onStopCommand?()
                currentTranscription = ""
                hasSpokenThisTurn = false
                vadCommitPending = false
                silenceTimer?.invalidate()
                silenceTimer = nil
                state = isWakeWordEnabled ? .idle : .listening
                restartRecognition()
                return
            }

            // Two regimes:
            // - AUDIBLE reply: require JARVIS/wake prefix at the start to defend against speaker echo.
            // - SILENT thinking/tool processing: there is no assistant audio to echo, and the
            //   recognizer buffer was cleared when the previous command committed. Any new speech
            //   is therefore a legitimate replacement turn, even without repeating "Jarvis".
            let replacement: String
            if isBargeInPaused {
                guard interruptPrefixAtStart(transcription) != nil else { return }
                replacement = extractCommandAfterInterruptPrefix(transcription)
            } else {
                let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                if interruptPrefixAtStart(trimmed) != nil {
                    replacement = extractCommandAfterInterruptPrefix(trimmed)
                } else if let recent = recentInterruptCommand(in: trimmed), !recent.isEmpty {
                    replacement = recent
                } else {
                    replacement = trimmed
                }
            }

            guard replacement.count > 2 else { return }

            print("[VoiceCommand] Barge-in during \(isBargeInPaused ? "audio" : "thinking"): '\(replacement)'")
            DiagnosticLogger.shared.log(
                "Voice",
                "Barge-in during \(isBargeInPaused ? "audio" : "thinking"): \(replacement)"
            )

            onInterruption?()
            state = .listening
            currentTranscription = replacement
            hasSpokenThisTurn = true
            lastSpeechRecognitionUpdateAt = Date()
            resetSilenceTimer()

            if result.isFinal {
                handleCommandComplete(replacement)
            }
        }
    }

    // MARK: - Barge-in helpers

    private func isStopPhrase(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("video") || lower.contains("stream") { return false }

        let reversedStopPhrases = [
            "pare jarvis", "para jarvis", "parar jarvis", "silêncio jarvis", "silencio jarvis",
            "chega jarvis", "cancela jarvis", "cancelar jarvis", "stop jarvis"
        ]
        if reversedStopPhrases.contains(where: { lower.hasPrefix($0) }) {
            DiagnosticLogger.shared.log("Voice", "Barge-in stop detected (stop-before-Jarvis)")
            return true
        }

        guard interruptPrefixAtStart(text) != nil else { return false }
        let command = extractCommandAfterInterruptPrefix(text).lowercased()
        let stopWords = [
            "stop", "be quiet", "shut up", "silence", "quiet", "enough", "cancel",
            "pare", "parar", "silêncio", "silencio", "cala a boca", "fica quieto", "chega", "cancela", "cancelar"
        ]
        let matched = stopWords.contains { command == $0 || command.hasPrefix($0 + " ") }
        if matched {
            DiagnosticLogger.shared.log("Voice", "Barge-in stop detected (Jarvis-before-stop)")
        }
        return matched
    }

    /// Finds the most recent JARVIS marker anywhere in the current STT buffer. Used only while the
    /// backend is silent/thinking; during audible speech we require a prefix at the start instead.
    private func recentInterruptCommand(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let lowerNSString = lower as NSString
        let originalNSString = trimmed as NSString
        let prefixes = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision"
        ]

        var bestLocation = NSNotFound
        var bestLength = 0
        for prefix in prefixes where !prefix.isEmpty {
            let range = lowerNSString.range(of: prefix, options: .backwards)
            if range.location != NSNotFound && (bestLocation == NSNotFound || range.location > bestLocation) {
                bestLocation = range.location
                bestLength = range.length
            }
        }
        guard bestLocation != NSNotFound else { return nil }
        guard lowerNSString.length - bestLocation <= 120 else { return nil }

        let end = bestLocation + bestLength
        guard end <= originalNSString.length else { return nil }
        return originalNSString.substring(from: end)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
    }

    private func interruptPrefixAtStart(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision"
        ]
        return prefixes.first { !$0.isEmpty && lower.hasPrefix($0) }
    }

    private func extractCommandAfterInterruptPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision"
        ]
        for prefix in prefixes where !prefix.isEmpty && lower.hasPrefix(prefix) {
            let index = trimmed.index(trimmed.startIndex, offsetBy: min(prefix.count, trimmed.count))
            return String(trimmed[index...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
        }
        return trimmed
    }

    private func wakeWordAtStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        let variations = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision"
        ]
        for variation in variations {
            if let range = lower.range(of: variation),
               lower.distance(from: lower.startIndex, to: range.lowerBound) <= 12 {
                return true
            }
        }
        return false
    }

    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
        guard bypassCooldown || !wakeWordCooldownActive else { return false }

        let lowercased = text.lowercased()
        let wakeWordLower = wakeWord.lowercased()
        let variations = [
            wakeWordLower,
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision",
            "a vision", "heavy vision", "have vision", "obey vision", "oak vision"
        ]

        let detected = variations.contains { !$0.isEmpty && lowercased.contains($0) }
        if detected {
            print("[VoiceCommand] Detected wake word in: '\(text)'")
        }
        return detected
    }

    private func extractCommandAfterWakeWord(_ text: String) -> String {
        let lowercased = text.lowercased()
        let variations = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis",
            "ok vision", "okay vision", "o.k. vision", "o k vision", "hey vision", "hi vision",
            "a vision", "heavy vision", "have vision", "obey vision", "oak vision"
        ]

        for variation in variations where !variation.isEmpty {
            if let range = lowercased.range(of: variation) {
                return String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    // MARK: - Wake / command completion

    private func handleWakeWordDetected() {
        print("[VoiceCommand] Wake word detected!")
        DiagnosticLogger.shared.log("Voice", "Wake word detected: \(wakeWord)")

        wakeWordCooldownActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Voice.wakeWordCooldown) { [weak self] in
            self?.wakeWordCooldownActive = false
        }

        state = .listening
        currentTranscription = ""
        lastSpeechRecognitionUpdateAt = nil
        vadCommitPending = false
        restartRecognition()
        startCommandTimeout()
        onWakeWordDetected?()
    }

    private func handleCommandComplete(_ text: String) {
        var command = text
        let wakeWordLower = wakeWord.lowercased()

        for prefix in [
            wakeWordLower, "ok jarvis", "okay jarvis", "hey jarvis", "jarvis",
            "hey vision", "ok vision", "okay vision"
        ] {
            if command.lowercased().hasPrefix(prefix) {
                command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !command.isEmpty else { return }

        if let lastUpdate = lastSpeechRecognitionUpdateAt {
            let endpointMs = Int(Date().timeIntervalSince(lastUpdate) * 1000)
            let profile = speechDetector.isAvailable ? "vad" : (TurnEndpointing.isLikelyComplete(command) ? "fast" : "grace")
            DiagnosticLogger.shared.log("Latency", "STT last-partial→command=\(endpointMs)ms profile=\(profile)")
        }
        lastSpeechRecognitionUpdateAt = nil

        print("[VoiceCommand] Command captured: \(command)")
        DiagnosticLogger.shared.log("Voice", "Command captured: \(command)")

        state = .processing
        vadCommitPending = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
        currentTranscription = ""

        // Clear Apple's accumulated recognition buffer before entering processing so anything
        // heard during thinking is a genuinely new utterance rather than the previous command tail.
        restartRecognition()
        onCommandCaptured?(command)
    }

    // MARK: - Timers

    /// Fallback endpointing only. When acoustic VAD is healthy, speechEnd owns turn commit.
    private func resetSilenceTimer() {
        guard !speechDetector.isAvailable else { return }
        silenceTimer?.invalidate()
        let timeout = TurnEndpointing.silenceTimeout(for: currentTranscription)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSilenceTimeout()
            }
        }
    }

    private func handleSilenceTimeout() {
        guard state == .listening || state == .conversationMode else { return }

        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else if state == .conversationMode {
            exitConversationMode()
        }
    }

    private func startCommandTimeout() {
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.commandTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleCommandTimeout()
            }
        }
    }

    private func handleCommandTimeout() {
        guard state == .listening else { return }

        print("[VoiceCommand] Command timeout")
        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else {
            state = .idle
            currentTranscription = ""
        }
    }
}

// MARK: - Errors

enum VoiceCommandError: LocalizedError {
    case notAuthorized
    case audioEngineUnavailable
    case requestCreationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized"
        case .audioEngineUnavailable: return "Audio engine unavailable"
        case .requestCreationFailed: return "Failed to create speech recognition request"
        }
    }
}
