// JARVIS - VoiceCommandService.swift
// Wake word detection and voice command capture using Apple Speech Recognition

import Foundation
import Speech
import AVFoundation

/// Voice command service for JARVIS.
///
/// Features:
/// - JARVIS-only wake word detection ("Ok Jarvis" / configured wake word)
/// - Command capture after wake word
/// - Acoustic VAD end-of-turn with adaptive timer fallback
/// - Conversation mode (follow-ups without wake word)
/// - Barge-in support, including while the backend is thinking
@MainActor
final class VoiceCommandService: ObservableObject {
    static let shared = VoiceCommandService()

    @Published var state: ListeningState = .idle
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    enum ListeningState: Equatable {
        case idle
        case listening
        case conversationMode
        case processing
    }

    var wakeWord: String {
        SettingsManager.shared.settings.wakeWord
    }

    var isWakeWordEnabled: Bool {
        SettingsManager.shared.settings.wakeWordEnabled
    }

    var playActivationSound: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    var onWakeWordDetected: (() -> Void)?
    var onStopCommand: (() -> Void)?
    var onCommandCaptured: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    var onConversationTimeout: (() -> Void)?

    /// True while reply audio is actually audible. During audible output interruption matching is
    /// deliberately conservative to reject speaker echo; while thinking silently, any new user
    /// utterance can replace the in-flight turn.
    var isBargeInPaused: Bool = false

    /// Returns true when the current backend can be interrupted (speaking OR processing/thinking).
    var shouldAllowInterrupt: (() -> Bool)?

    /// True while Gemini owns the microphone as a direct PCM stream. App/lifecycle recovery paths
    /// must not start a second Apple Speech recognizer while this flag is set.
    var isWakeRecoverySuppressed: Bool = false

    /// ChatGPT-style conversation lifecycle: after the initial wake word, silence is only an idle
    /// pulse. It must NOT close the active conversation and require another wake phrase.
    var persistentConversationMode: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0

    private var audioEngine: AVAudioEngine?
    private var lastRecognizerRestart = Date.distantPast
    private var wakeWordRestartScheduled = false
    private let minRestartInterval: TimeInterval = 0.6

    private var silenceTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var conversationTimeoutTimer: Timer?
    private var wakeWordCooldownActive: Bool = false
    private var speakerVerificationPending: Bool = false

    /// Silero VAD via FluidAudio. When available, this is the primary end-of-turn signal.
    private let speechDetector = SpeechActivityDetector()
    private var vadCommitPending = false
    private var hasSpokenThisTurn: Bool = false
    private var lastSpeechRecognitionUpdateAt: Date?

    private init() {
        setupSpeechDetector()
    }

    /// Product-specific phrases accepted by this branch. Intentionally contains no Vision aliases,
    /// so the upstream OpenVision app and Project JARVIS remain behaviorally separate.
    private var jarvisWakeVariants: [String] {
        var values = [
            wakeWord.lowercased(),
            "ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis", "jarvis"
        ]
        var seen = Set<String>()
        values = values.filter { !$0.isEmpty && seen.insert($0).inserted }
        return values
    }

    /// Some AVAudio/Speech calls raise Objective-C NSException instead of Swift Error.
    /// Rapid recognizer restarts can otherwise terminate the process with SIGABRT.
    private func removeTapSafely(from inputNode: AVAudioInputNode, context: String) {
        if let reason = OVCatchException({
            inputNode.removeTap(onBus: 0)
        }) {
            DiagnosticLogger.shared.log("Voice", "removeTap ignored [\(context)]: \(reason)")
        }
    }

    private nonisolated func appendSafely(
        _ buffer: AVAudioPCMBuffer,
        to request: SFSpeechAudioBufferRecognitionRequest
    ) {
        if let reason = OVCatchException({
            request.append(buffer)
        }) {
            Task { @MainActor in
                DiagnosticLogger.shared.log("Voice", "Speech append exception suppressed: \(reason)")
            }
        }
    }

    private func setupSpeechDetector() {
        speechDetector.onSpeechStart = { [weak self] in
            guard let self else { return }
            if self.state == .idle || self.state == .listening || self.state == .conversationMode {
                SpeakerVerificationService.shared.resetRecentAudio()
            }
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

    private func handleSpeechEnded() {
        guard state == .listening || state == .conversationMode else { return }
        guard hasSpokenThisTurn, !currentTranscription.isEmpty else { return }

        MetricsCollector.shared.markSpeechEnd()
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

    func startListening() throws {
        guard !isWakeRecoverySuppressed else {
            DiagnosticLogger.shared.log("Voice", "Recognizer start skipped: direct Gemini owns microphone")
            return
        }
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

        removeTapSafely(from: inputNode, context: "startListening preinstall")
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable (format \(recordingFormat.sampleRate)Hz/\(recordingFormat.channelCount)ch)")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.appendSafely(buffer, to: recognitionRequest)
                SpeakerVerificationService.shared.feed(buffer: buffer)
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
            removeTapSafely(from: audioEngine.inputNode, context: "startListening start failure")
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
        request.contextualStrings = jarvisWakeVariants.map { variant in
            variant.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        }
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

        if let inputNode = audioEngine?.inputNode {
            removeTapSafely(from: inputNode, context: "stopListening")
        }
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

        // Count every direct restart too. Previously a scheduled recognizer restart could fire
        // immediately after a state-driven restart and churn the audio tap twice.
        lastRecognizerRestart = Date()

        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let inputNode = audioEngine?.inputNode {
            removeTapSafely(from: inputNode, context: "restartRecognition teardown")
        }

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
        // The old restart path removed the same tap twice. The safe teardown above is enough.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable on reinstall — skipping tap")
            self.recognitionRequest = nil
            return
        }

        speechDetector.reset()
        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.appendSafely(buffer, to: recognitionRequest)
                SpeakerVerificationService.shared.feed(buffer: buffer)
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
        MetricsCollector.shared.count("recognition_restart")
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
                requestWakeWordActivation()
            }

        case .listening, .conversationMode:
            // The wake marker is removable only when it is actually a PREFIX. Build 33 searched
            // anywhere in the sentence, so a natural phrase such as “Você está me ouvindo Jarvis?”
            // became an empty command and remained stuck on Listening forever. Mid/end-sentence
            // mentions of Jarvis are ordinary user content and must be preserved.
            var command = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerCommand = command.lowercased()
            for phrase in jarvisWakeVariants where lowerCommand.hasPrefix(phrase) {
                command = String(command.dropFirst(phrase.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
                break
            }

            currentTranscription = command
            if !command.isEmpty {
                lastSpeechRecognitionUpdateAt = Date()
            }

            if command.count > 3 {
                hasSpokenThisTurn = true
                conversationTimeoutTimer?.invalidate()
            }

            resetSilenceTimer()

            if result.isFinal && !command.isEmpty {
                handleCommandComplete(command)
            }

        case .processing:
            // A bare explicit wake phrase must always be able to recover a stuck/slow turn. The
            // previous implementation required a replacement command after the wake phrase, so
            // saying only "Ok Jarvis" while OpenClaw/Gemini was processing did nothing.
            let explicitWake = isExplicitWakePhrase(transcription)
            let allowInterrupt = shouldAllowInterrupt?() ?? false
            guard allowInterrupt || explicitWake else { return }

            if explicitWake && extractCommandAfterWakeWord(transcription).isEmpty {
                DiagnosticLogger.shared.log("Voice", "Explicit wake recovered processing state")
                onInterruption?()
                requestWakeWordActivation()
                return
            }

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

            // Audible reply requires a JARVIS prefix to avoid speaker echo. While the backend is
            // silently thinking/tool-running, fresh speech can replace the in-flight turn directly.
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

        var bestLocation = NSNotFound
        var bestLength = 0
        for prefix in jarvisWakeVariants {
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
        return jarvisWakeVariants.first { lower.hasPrefix($0) }
    }

    private func extractCommandAfterInterruptPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in jarvisWakeVariants where lower.hasPrefix(prefix) {
            let index = trimmed.index(trimmed.startIndex, offsetBy: min(prefix.count, trimmed.count))
            return String(trimmed[index...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-–—"))
        }
        return trimmed
    }

    private func wakeWordAtStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        for variation in jarvisWakeVariants {
            if let range = lower.range(of: variation),
               lower.distance(from: lower.startIndex, to: range.lowerBound) <= 12 {
                return true
            }
        }
        return false
    }

    /// Strong wake forms used when a turn is already processing. Deliberately excludes the
    /// bare word "Jarvis" so the assistant's own speech cannot easily self-trigger recovery.
    private func isExplicitWakePhrase(_ text: String) -> Bool {
        let lower = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r,.:;!?-–—"))
        let explicit = ["ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis"]
        return explicit.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
        guard bypassCooldown || !wakeWordCooldownActive else { return false }
        let lowercased = text.lowercased()
        let detected = jarvisWakeVariants.contains { lowercased.contains($0) }
        if detected {
            print("[VoiceCommand] Detected JARVIS wake word in: '\(text)'")
        }
        return detected
    }

    private func extractCommandAfterWakeWord(_ text: String) -> String {
        let lowercased = text.lowercased()
        for variation in jarvisWakeVariants {
            if let range = lowercased.range(of: variation) {
                return String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// Verify the wake speaker locally before activation when Owner Voice Lock is enabled.
    private func requestWakeWordActivation() {
        guard !speakerVerificationPending else { return }

        let settings = SettingsManager.shared.settings
        guard settings.voiceOwnerLockEnabled else {
            handleWakeWordDetected()
            return
        }

        speakerVerificationPending = true
        let sample = SpeakerVerificationService.shared.snapshotRecentAudio(maxSeconds: 4.0)
        let threshold = Float(settings.voiceOwnerSimilarityThreshold)

        Task { [weak self] in
            guard let self else { return }
            let result = await SpeakerVerificationService.shared.verify(samples: sample, threshold: threshold)
            self.speakerVerificationPending = false

            if result.isMatch {
                DiagnosticLogger.shared.log(
                    "VoiceAuth",
                    String(format: "Wake accepted score=%.3f threshold=%.3f", result.similarity ?? -1, threshold)
                )
                self.handleWakeWordDetected()
            } else {
                DiagnosticLogger.shared.log(
                    "VoiceAuth",
                    String(format: "Wake rejected score=%.3f threshold=%.3f reason=%@", result.similarity ?? -1, threshold, result.reason)
                )
                self.currentTranscription = ""
                self.hasSpokenThisTurn = false
                self.vadCommitPending = false
                self.wakeWordCooldownActive = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.wakeWordCooldownActive = false
                }
                self.restartRecognition()
            }
        }
    }

    private func handleWakeWordDetected() {
        print("[VoiceCommand] JARVIS wake word detected!")
        DiagnosticLogger.shared.log("Voice", "Wake word detected: \(wakeWord)")
        MetricsCollector.shared.count("wake_word_detected")

        wakeWordCooldownActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Voice.wakeWordCooldown) { [weak self] in
            self?.wakeWordCooldownActive = false
        }

        state = .listening
        currentTranscription = ""
        SpeakerVerificationService.shared.resetRecentAudio()
        lastSpeechRecognitionUpdateAt = nil
        vadCommitPending = false
        restartRecognition()
        startCommandTimeout()
        onWakeWordDetected?()
    }

    private func handleCommandComplete(_ text: String) {
        var command = text
        for prefix in jarvisWakeVariants where command.lowercased().hasPrefix(prefix) {
            command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
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
        MetricsCollector.shared.count("command_captured")

        state = .processing
        vadCommitPending = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
        currentTranscription = ""

        let settings = SettingsManager.shared.settings
        let mustVerifyOwner = settings.voiceOwnerLockEnabled
        // CAM++ does not need the whole rolling buffer. Bounding verification to the most recent
        // 4 seconds cuts embedding work on long commands while preserving enough speech for a
        // stable speaker match. The buffer is reset at speech start, so this remains turn-local.
        let sample = mustVerifyOwner
            ? SpeakerVerificationService.shared.snapshotRecentAudio(maxSeconds: 4.0)
            : []
        let threshold = Float(settings.voiceOwnerSimilarityThreshold)

        restartRecognition()

        guard mustVerifyOwner else {
            onCommandCaptured?(command)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let verifyStartedAt = Date()
            let result = await SpeakerVerificationService.shared.verify(samples: sample, threshold: threshold)
            let verifyMs = Int(Date().timeIntervalSince(verifyStartedAt) * 1000)
            DiagnosticLogger.shared.log(
                "Latency",
                "Speaker verification=\(verifyMs)ms audio=\(String(format: "%.2f", Double(sample.count) / 16000.0))s"
            )
            if result.isMatch {
                DiagnosticLogger.shared.log(
                    "VoiceAuth",
                    String(format: "Command accepted score=%.3f threshold=%.3f", result.similarity ?? -1, threshold)
                )
                self.onCommandCaptured?(command)
            } else {
                DiagnosticLogger.shared.log(
                    "VoiceAuth",
                    String(format: "Command rejected score=%.3f threshold=%.3f reason=%@", result.similarity ?? -1, threshold, result.reason)
                )
                self.currentTranscription = ""
                self.hasSpokenThisTurn = false
                self.vadCommitPending = false
                self.state = self.persistentConversationMode
                    ? .conversationMode
                    : (self.isWakeWordEnabled ? .idle : .listening)
                self.restartRecognition()
            }
        }
    }

    /// Hybrid endpointing. Acoustic VAD is the fast primary signal, but it must never be the
    /// only path to committing a turn: room noise, Bluetooth routes, or a missed Silero speechEnd
    /// can otherwise leave Conversation Mode on Listening forever. Every fresh STT partial arms a
    /// conservative lexical watchdog; a real VAD speechEnd replaces it with the shorter VAD grace.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let lexicalTimeout = TurnEndpointing.silenceTimeout(for: currentTranscription)
        let timeout = speechDetector.isAvailable ? max(1.25, lexicalTimeout) : lexicalTimeout
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.speechDetector.isAvailable {
                    DiagnosticLogger.shared.log(
                        "VAD",
                        "speechEnd fallback timer committed turn after \(Int(timeout * 1000))ms"
                    )
                }
                self.handleSilenceTimeout()
            }
        }
    }

    private func handleSilenceTimeout() {
        guard state == .listening || state == .conversationMode else { return }

        // Fallback path when VAD did not fire; first-wins keeps the real VAD timestamp when it did.
        MetricsCollector.shared.markSpeechEnd()

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
