from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"Expected text not found in {path}: {old[:160]!r}")
    p.write_text(text.replace(old, new, 1))


# 1) Persistent diagnostics logger, entirely on-device (no Xcode/Mac required).
Path("OpenVision/Services/Diagnostics").mkdir(parents=True, exist_ok=True)
Path("OpenVision/Services/Diagnostics/DiagnosticLogger.swift").write_text(r'''// OpenVision - DiagnosticLogger.swift
// Persistent in-app diagnostics for Windows/GitHub Actions/Sideloadly development.

import Foundation
import Combine

@MainActor
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var entries: [String] = []
    let fileURL: URL

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let maxEntries = 1000

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("jarvis-diagnostics.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), !existing.isEmpty {
            entries = Array(existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(maxEntries))
        }

        log("App", "Diagnostics initialized — OpenVision \(Config.appVersion) (\(Config.buildNumber))")
    }

    func log(_ category: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(line + "\n")
        print("[Diagnostics] \(line)")
    }

    var exportText: String {
        entries.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        try? Data().write(to: fileURL, options: .atomic)
        log("App", "Diagnostics cleared")
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("[Diagnostics] File write failed: \(error.localizedDescription)")
        }
    }
}
''')


# 2) Diagnostics UI: view/copy/share/clear logs directly on iPhone.
Path("OpenVision/Views/Settings/DiagnosticsView.swift").write_text(r'''// OpenVision - DiagnosticsView.swift

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @StateObject private var logger = DiagnosticLogger.shared
    @State private var copied = false

    var body: some View {
        List {
            Section("Build") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(Config.appVersion) (\(Config.buildNumber))")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ScrollView {
                    Text(logger.exportText.isEmpty ? "No diagnostic events yet." : logger.exportText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 300)
            } header: {
                Text("Logs")
            } footer: {
                Text("Logs may include speech transcripts and technical state, but never the Gemini API key.")
            }

            Section("Actions") {
                Button {
                    UIPasteboard.general.string = logger.exportText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Logs", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                ShareLink(item: logger.fileURL) {
                    Label("Share Log File", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    logger.clear()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
''')


# 3) Settings entry for diagnostics.
replace_once(
    "OpenVision/Views/Settings/SettingsView.swift",
    '''                    NavigationLink {
                        DocumentsSettingsView()
                    } label: {
                        Label("My Documents", systemImage: "books.vertical")
                    }

                    Toggle(isOn: $settingsManager.settings.autoReconnect) {''',
    '''                    NavigationLink {
                        DocumentsSettingsView()
                    } label: {
                        Label("My Documents", systemImage: "books.vertical")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics / Logs", systemImage: "waveform.path.ecg")
                    }

                    Toggle(isOn: $settingsManager.settings.autoReconnect) {'''
)


# 4) Portuguese speech recognition + proper Never timeout + dictation after wake word.
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    'private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))',
    'private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))'
)

replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''        request.shouldReportPartialResults = true
        request.taskHint = .search
        var phrases = ["Ok Vision", "Okay Vision", "Hey Vision", "Vision"]''',
    '''        request.shouldReportPartialResults = true
        // Short-phrase search while idle for the wake word; full dictation once activated.
        // Using .search for normal questions was hurting Brazilian Portuguese/place-name accuracy.
        request.taskHint = state == .idle ? .search : .dictation
        var phrases = ["Ok Vision", "Okay Vision", "Hey Vision", "Vision"]'''
)

replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''    func enterConversationMode() {
        // Restart recognition to clear accumulated transcription
        restartRecognition()

        state = .conversationMode
        hasSpokenThisTurn = false''',
    '''    func enterConversationMode() {
        // Set the state BEFORE rebuilding recognition so configureRecognitionRequest uses
        // dictation rather than wake-word search for follow-up questions.
        state = .conversationMode
        restartRecognition()

        hasSpokenThisTurn = false'''
)

replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''        // Transition to listening
        state = .listening
        currentTranscription = ""

        // Start command timeout''',
    '''        // Transition to listening and rebuild recognition in dictation mode.
        state = .listening
        currentTranscription = ""
        restartRecognition()

        // Start command timeout'''
)

replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '''    /// Start conversation timeout (auto-exit after silence)
    private func startConversationTimeout() {
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleConversationTimeout()
            }
        }
    }''',
    '''    /// Start conversation timeout using the user's Voice settings. A value of 0 means Never.
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
    }'''
)

# Voice diagnostics at useful boundaries.
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '        print("[VoiceCommand] Started listening - audio engine running")',
    '        print("[VoiceCommand] Started listening - audio engine running")\n        DiagnosticLogger.shared.log("Voice", "Recognizer started locale=pt-BR state=\\(state) route=\\(AudioSessionManager.shared.currentRouteDescription)")'
)
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '        print("[VoiceCommand] 🎤 heard(\\(state)): \\"\\(transcription)\\"")',
    '        print("[VoiceCommand] 🎤 heard(\\(state)): \\"\\(transcription)\\"")\n        DiagnosticLogger.shared.log("STT", "heard[\\(state)]: \\(transcription)")'
)
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '        print("[VoiceCommand] Wake word detected!")',
    '        print("[VoiceCommand] Wake word detected!")\n        DiagnosticLogger.shared.log("Voice", "Wake word detected: \\(wakeWord)")'
)
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '        print("[VoiceCommand] Command captured: \\(command)")',
    '        print("[VoiceCommand] Command captured: \\(command)")\n        DiagnosticLogger.shared.log("Voice", "Command captured: \\(command)")'
)
replace_once(
    "OpenVision/Services/Voice/VoiceCommandService.swift",
    '            print("[VoiceCommand] Conversation timeout - no speech detected")',
    '            print("[VoiceCommand] Conversation timeout - no speech detected")\n            DiagnosticLogger.shared.log("Voice", "Conversation timeout fired")'
)


# 5) Gemini defaults to pt-BR and logs the request/response/audio path.
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        The current date and time is''',
    '''        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        RESPOND IN BRAZILIAN PORTUGUESE (pt-BR). YOU MUST RESPOND UNMISTAKABLY IN BRAZILIAN PORTUGUESE unless the user explicitly asks for another language.

        The current date and time is'''
)

replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        connectionState = .connecting
        onConnectionStateChanged?(connectionState)''',
    '''        connectionState = .connecting
        onConnectionStateChanged?(connectionState)
        DiagnosticLogger.shared.log("Gemini", "Connecting model=\(Constants.GeminiLive.modelName)")'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '            print("[GeminiLive] Connected")',
    '            print("[GeminiLive] Connected")\n            DiagnosticLogger.shared.log("Gemini", "Connected and setup complete")'
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''            closeWebSocket()
            throw error''',
    '''            DiagnosticLogger.shared.log("Gemini", "Connect failed: \(error.localizedDescription)")
            closeWebSocket()
            throw error'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '        print("[GeminiLive] Disconnecting")',
    '        print("[GeminiLive] Disconnecting")\n        DiagnosticLogger.shared.log("Gemini", "Disconnecting")'
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '        try await sendJSON(setup)',
    '        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO + pt-BR system instruction")\n        try await sendJSON(setup)'
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        try await sendJSON(message)
    }

    /// Interrupt the AI''',
    '''        DiagnosticLogger.shared.log("Gemini", "Sending text turn: \(text)")
        try await sendJSON(message)
    }

    /// Interrupt the AI'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '                        print("[GeminiLive] Receive error: \(error)")',
    '                        print("[GeminiLive] Receive error: \(error)")\n                        DiagnosticLogger.shared.log("Gemini", "Receive error: \(error.localizedDescription)")'
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        if json["setupComplete"] != nil {
            isSetupComplete = true
            return
        }''',
    '''        if json["setupComplete"] != nil {
            isSetupComplete = true
            DiagnosticLogger.shared.log("Gemini", "Received setupComplete")
            return
        }'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        if content["turnComplete"] as? Bool == true {
            isModelSpeaking = false
            isProcessing = false
            onTurnComplete?()''',
    '''        if content["turnComplete"] as? Bool == true {
            isModelSpeaking = false
            isProcessing = false
            DiagnosticLogger.shared.log("Gemini", "Turn complete")
            onTurnComplete?()'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''                    isModelSpeaking = true
                    isProcessing = true

                    if let onAudioReceived {''',
    '''                    isModelSpeaking = true
                    isProcessing = true
                    DiagnosticLogger.shared.log("GeminiAudio", "Received PCM chunk bytes=\(audioData.count)")

                    if let onAudioReceived {'''
)
replace_once(
    "OpenVision/Services/GeminiLive/GeminiLiveService.swift",
    '''        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String, !text.isEmpty {
            onOutputTranscription?(text)''',
    '''        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String, !text.isEmpty {
            DiagnosticLogger.shared.log("Gemini", "Output transcript: \(text)")
            onOutputTranscription?(text)'''
)


# 6) Playback diagnostics.
replace_once(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '        print("[AudioPlayback] Engine started")',
    '        print("[AudioPlayback] Engine started")\n        DiagnosticLogger.shared.log("Audio", "Playback engine started format=\\(outputFormat.sampleRate)Hz/\\(outputFormat.channelCount)ch")'
)
replace_once(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '''    func playAudio(data: Data) {
        guard let engine = audioEngine, let player = playerNode else {''',
    '''    func playAudio(data: Data) {
        DiagnosticLogger.shared.log("Audio", "playAudio bytes=\(data.count)")
        guard let engine = audioEngine, let player = playerNode else {'''
)
replace_once(
    "OpenVision/Services/Audio/AudioPlaybackService.swift",
    '            print("[AudioPlayback] Engine not setup")',
    '            print("[AudioPlayback] Engine not setup")\n            DiagnosticLogger.shared.log("Audio", "ERROR: playback engine not setup")'
)


# 7) Build number 13 so the installed IPA is unmistakable.
replace_once(
    "project.yml",
    '    CURRENT_PROJECT_VERSION: "12"',
    '    CURRENT_PROJECT_VERSION: "13"'
)

# Remove one-shot patch machinery from final branch contents.
Path(".github/workflows/apply-build13.yml").unlink(missing_ok=True)
Path(".github/scripts/apply_build13.py").unlink(missing_ok=True)
