from pathlib import Path
import subprocess

voice_path = Path("JARVIS/Services/Voice/VoiceCommandService.swift")
viewmodel_path = Path("JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift")
app_path = Path("JARVIS/App/JARVISApp.swift")
gemini_path = Path("JARVIS/Services/GeminiLive/GeminiLiveService.swift")
openclaw_path = Path("JARVIS/Services/OpenClaw/OpenClawService.swift")
project_path = Path("project.yml")
notes_path = Path("JARVIS_BUILD_NOTES.md")

voice = voice_path.read_text(encoding="utf-8")
viewmodel = viewmodel_path.read_text(encoding="utf-8")
app = app_path.read_text(encoding="utf-8")
gemini = gemini_path.read_text(encoding="utf-8")
openclaw = openclaw_path.read_text(encoding="utf-8")
project = project_path.read_text(encoding="utf-8")
notes = notes_path.read_text(encoding="utf-8")


def replace_once(text, old, new, label):
    assert old in text, f"{label} anchor changed"
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# VoiceCommandService: exclusive-mic guard + recoverable wake word while processing.
# ---------------------------------------------------------------------------
voice = replace_once(
    voice,
    '''    /// Returns true when the current backend can be interrupted (speaking OR processing/thinking).
    var shouldAllowInterrupt: (() -> Bool)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
''',
    '''    /// Returns true when the current backend can be interrupted (speaking OR processing/thinking).
    var shouldAllowInterrupt: (() -> Bool)?

    /// True while Gemini owns the microphone as a direct PCM stream. App/lifecycle recovery paths
    /// must not start a second Apple Speech recognizer while this flag is set.
    var isWakeRecoverySuppressed: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
''',
    "voice mic ownership flag",
)

voice = replace_once(
    voice,
    '''    func startListening() throws {
        guard authorizationStatus == .authorized else {
''',
    '''    func startListening() throws {
        guard !isWakeRecoverySuppressed else {
            DiagnosticLogger.shared.log("Voice", "Recognizer start skipped: direct Gemini owns microphone")
            return
        }
        guard authorizationStatus == .authorized else {
''',
    "voice suppressed start guard",
)

voice = replace_once(
    voice,
    '''        case .processing:
            let allowInterrupt = shouldAllowInterrupt?() ?? false
            guard allowInterrupt else { return }

            if isStopPhrase(transcription) {
''',
    '''        case .processing:
            // A bare explicit wake phrase must always be able to recover a stuck/slow turn. The
            // previous implementation required a replacement command after the wake phrase, so
            // saying only "Ok Jarvis" while OpenClaw/Gemini was processing did nothing.
            let explicitWake = isExplicitWakePhrase(transcription)
            let allowInterrupt = shouldAllowInterrupt?() ?? false
            guard allowInterrupt || explicitWake else { return }

            if explicitWake && extractCommandAfterWakeWord(transcription).isEmpty {
                DiagnosticLogger.shared.log("Voice", "Explicit wake recovered processing state")
                onInterruption?()
                handleWakeWordDetected()
                return
            }

            if isStopPhrase(transcription) {
''',
    "voice processing wake recovery",
)

voice = replace_once(
    voice,
    '''    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
''',
    '''    /// Strong wake forms used when a turn is already processing. Deliberately excludes the
    /// bare word "Jarvis" so the assistant's own speech cannot easily self-trigger recovery.
    private func isExplicitWakePhrase(_ text: String) -> Bool {
        let lower = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \\t\\n\\r,.:;!?-–—"))
        let explicit = ["ok jarvis", "okay jarvis", "o.k. jarvis", "o k jarvis", "hey jarvis"]
        return explicit.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
''',
    "voice explicit wake helper",
)


# ---------------------------------------------------------------------------
# VoiceAgentViewModel: direct Gemini exclusively owns mic; OpenClaw is interruptible.
# ---------------------------------------------------------------------------
viewmodel = replace_once(
    viewmodel,
    '''    private func startDirectGeminiVoiceMode() throws {
        directGeminiTimeoutTask?.cancel()
        directGeminiAwaitingNewInput = true

        if voiceCommandService.isListening {
''',
    '''    private func startDirectGeminiVoiceMode() throws {
        directGeminiTimeoutTask?.cancel()
        directGeminiAwaitingNewInput = true

        // Direct Gemini streams PCM continuously. Mark microphone ownership BEFORE stopping the
        // wake recognizer so scene-activation recovery cannot race in and start Apple Speech again.
        voiceCommandService.isWakeRecoverySuppressed = true
        if voiceCommandService.isListening {
''',
    "viewmodel direct mic acquire",
)

viewmodel = replace_once(
    viewmodel,
    '''        } catch {
            audioCapture.onAudioCaptured = nil
            isDirectGeminiVoiceMode = false
            if settingsManager.settings.wakeWordEnabled,
''',
    '''        } catch {
            audioCapture.onAudioCaptured = nil
            isDirectGeminiVoiceMode = false
            voiceCommandService.isWakeRecoverySuppressed = false
            if settingsManager.settings.wakeWordEnabled,
''',
    "viewmodel direct mic acquire rollback",
)

viewmodel = replace_once(
    viewmodel,
    '''        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil
        isDirectGeminiVoiceMode = false
        directGeminiAwaitingNewInput = true
''',
    '''        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil
        isDirectGeminiVoiceMode = false
        voiceCommandService.isWakeRecoverySuppressed = false
        directGeminiAwaitingNewInput = true
''',
    "viewmodel direct mic release",
)

viewmodel = replace_once(
    viewmodel,
    '''            return self.ttsService.isSpeaking
                || self.geminiStreamingTTS.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || GeminiLiveService.shared.isProcessing
                || self.audioPlayback.isPlaying
''',
    '''            return self.ttsService.isSpeaking
                || self.geminiStreamingTTS.isSpeaking
                || KokoroTTSService.shared.isSpeaking
                || GeminiLiveService.shared.isModelSpeaking
                || GeminiLiveService.shared.isProcessing
                || OpenClawService.shared.isProcessing
                || OpenClawService.shared.isToolRunning
                || self.agentState == .thinking
                || self.agentState == .toolRunning
                || self.audioPlayback.isPlaying
''',
    "viewmodel openclaw interrupt eligibility",
)

viewmodel = replace_once(
    viewmodel,
    '''    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }

        // Configure audio for glasses before starting to listen
''',
    '''    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }
        guard !voiceCommandService.isWakeRecoverySuppressed else {
            DiagnosticLogger.shared.log("Voice", "Wake listener start skipped: direct Gemini owns microphone")
            return
        }

        // Configure audio for glasses before starting to listen
''',
    "viewmodel wake start mic guard",
)


# ---------------------------------------------------------------------------
# App lifecycle: never revive Apple Speech or tear down Gemini behind the ViewModel while
# direct Gemini owns the mic. This was visible in Build 31 logs as both capture paths running.
# ---------------------------------------------------------------------------
app = replace_once(
    app,
    '''                if phase == .background,
                   !GeminiLiveService.shared.isProcessing,
''',
    '''                if phase == .background,
                   !VoiceCommandService.shared.isWakeRecoverySuppressed,
                   !GeminiLiveService.shared.isProcessing,
''',
    "app background direct gemini guard",
)

app = replace_once(
    app,
    '''                if phase == .active,
                   SettingsManager.shared.settings.wakeWordEnabled,
                   VoiceCommandService.shared.authorizationStatus == .authorized,
                   !VoiceCommandService.shared.isListening {
''',
    '''                if phase == .active,
                   SettingsManager.shared.settings.wakeWordEnabled,
                   VoiceCommandService.shared.authorizationStatus == .authorized,
                   !VoiceCommandService.shared.isWakeRecoverySuppressed,
                   !VoiceCommandService.shared.isListening {
''',
    "app active wake recovery mic guard",
)


# ---------------------------------------------------------------------------
# Gemini: make the iPhone LOCAL civil date explicit instead of exposing only an ISO timestamp
# that the model can reinterpret as UTC around evening hours in Brazil.
# ---------------------------------------------------------------------------
gemini = replace_once(
    gemini,
    '''    private func buildSystemPrompt() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var prompt = """
''',
    '''    private func buildSystemPrompt() -> String {
        let instant = Date()
        let localTimeZone = TimeZone.current
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "pt_BR")
        localFormatter.timeZone = localTimeZone
        localFormatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy, HH:mm:ss"
        let localNow = localFormatter.string(from: instant)

        let localDateFormatter = DateFormatter()
        localDateFormatter.locale = Locale(identifier: "pt_BR")
        localDateFormatter.timeZone = localTimeZone
        localDateFormatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy"
        let localToday = localDateFormatter.string(from: instant)

        var prompt = """
''',
    "gemini local date formatter",
)

gemini = replace_once(
    gemini,
    '''        The current date and time is \\(now) in the user's local time zone. Base any time on this.

        IMPORTANT: when the user asks JARVIS to perform an iPhone action that has a matching tool, CALL THE TOOL instead of merely explaining how to do it.
''',
    '''        DATE/TIME GROUND TRUTH FROM THE IPHONE: right now locally it is \\(localNow), time zone \\(localTimeZone.identifier). The local civil date called "hoje" is exactly \\(localToday). Treat this iPhone-local date as authoritative. DO NOT convert it to UTC and accidentally call the next UTC date "today". For questions such as "que dia é hoje?", "hoje é dia quanto?" or "que horas são?", answer from this local clock. If the user explicitly asks to search the web, you may call web_search, but reconcile any result to this same iPhone-local calendar date.

        IMPORTANT: when the user asks JARVIS to perform an iPhone action that has a matching tool, CALL THE TOOL instead of merely explaining how to do it.
''',
    "gemini local date instruction",
)


# ---------------------------------------------------------------------------
# OpenClaw: one provider failure can emit multiple near-identical chat.error events. Speak one
# friendly error per turn and fully clear tool state so the voice loop does not churn or stick.
# ---------------------------------------------------------------------------
openclaw = replace_once(
    openclaw,
    '''    private var partialResponseSource: PartialResponseSource?
    private var turnWatchdogTask: Task<Void, Never>?

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
''',
    '''    private var partialResponseSource: PartialResponseSource?
    private var turnWatchdogTask: Task<Void, Never>?
    private var lastProviderErrorSpokenAt = Date.distantPast
    private var lastProviderErrorSpokenText = ""

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
''',
    "openclaw provider error dedupe state",
)

openclaw = replace_once(
    openclaw,
    '''        isProcessing = true
        accumulatedResponse = ""
        partialResponseSource = nil
        turnWatchdogTask?.cancel()
''',
    '''        isProcessing = true
        accumulatedResponse = ""
        partialResponseSource = nil
        lastProviderErrorSpokenAt = .distantPast
        lastProviderErrorSpokenText = ""
        turnWatchdogTask?.cancel()
''',
    "openclaw reset provider error dedupe",
)

openclaw = replace_once(
    openclaw,
    '''            case "error":
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
''',
    '''            case "error":
                let message = payload["errorMessage"]?.stringValue ?? "OpenClaw error"
                let friendly = friendlyErrorMessage(for: message)
                let now = Date()
                if friendly == lastProviderErrorSpokenText,
                   now.timeIntervalSince(lastProviderErrorSpokenAt) < 2.0 {
                    DiagnosticLogger.shared.log("OpenClaw", "Duplicate provider error ignored")
                    return
                }
                lastProviderErrorSpokenText = friendly
                lastProviderErrorSpokenAt = now
                turnWatchdogTask?.cancel()
                turnWatchdogTask = nil
                activeRunId = nil
                isProcessing = false
                isToolRunning = false
                currentToolName = nil
                lastError = friendly
                DiagnosticLogger.shared.log("OpenClaw", "Provider error suppressed: \\(message)")
                accumulatedResponse = ""
                partialResponseSource = nil
                onToolStatusChanged?(nil, false)
                onAgentMessage?(friendly)
                onProcessingChanged?(false)
''',
    "openclaw dedupe provider error events",
)


# Build number + notes.
assert 'CURRENT_PROJECT_VERSION: "31"' in project, "Build number is not 31"
project = project.replace('CURRENT_PROJECT_VERSION: "31"', 'CURRENT_PROJECT_VERSION: "32"', 1)

notes += '''\n\n## Build 32 — voice/session stability\n- Prevents Apple Speech wake-listener recovery from starting while direct Gemini PCM owns the microphone.\n- Prevents background lifecycle cleanup from disconnecting an active direct-Gemini voice session behind the ViewModel.\n- Allows explicit “Ok Jarvis” to recover a stuck/slow processing turn and makes OpenClaw processing/tool work interruptible.\n- Grounds “today” in the iPhone local civil date/time instead of an ambiguous UTC interpretation.\n- Deduplicates repeated OpenClaw provider/rate-limit error events and clears tool state cleanly.\n'''

voice_path.write_text(voice, encoding="utf-8")
viewmodel_path.write_text(viewmodel, encoding="utf-8")
app_path.write_text(app, encoding="utf-8")
gemini_path.write_text(gemini, encoding="utf-8")
openclaw_path.write_text(openclaw, encoding="utf-8")
project_path.write_text(project, encoding="utf-8")
notes_path.write_text(notes, encoding="utf-8")

subprocess.run(["git", "diff", "--check"], check=True)
subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
subprocess.run([
    "git", "add",
    str(voice_path), str(viewmodel_path), str(app_path), str(gemini_path),
    str(openclaw_path), str(project_path), str(notes_path),
], check=True)
subprocess.run([
    "git", "commit", "-m",
    "Build 32: fix wake recovery, Gemini date and OpenClaw errors",
], check=True)
subprocess.run(["git", "push", "origin", "HEAD:jarvis-dev"], check=True)
