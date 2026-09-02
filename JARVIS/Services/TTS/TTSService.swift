// JARVIS - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer

import AVFoundation
import Foundation

/// Text-to-speech service for text-based backends such as OpenClaw.
@MainActor
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking: Bool = false

    var onSpeechStarted: (() -> Void)?
    var onSpeechEnded: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingUtterances = 0
    private var streamingActive = false

    // JARVIS' primary spoken language is Brazilian Portuguese. Never read Portuguese
    // using an English voice (the previous default was en-US and the picker only exposed
    // English voices, which caused a strong foreign accent in OpenClaw replies).
    private var selectedVoice: AVSpeechSynthesisVoice? {
        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language.lowercased().hasPrefix("pt") {
            return voice
        }

        return AVSpeechSynthesisVoice(language: "pt-BR")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.language.lowercased().hasPrefix("pt-br")
            })
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.language.lowercased().hasPrefix("pt")
            })
    }

    /// Get all available voices for a language.
    static func availableVoices(for languageCode: String = "pt-BR") -> [AVSpeechSynthesisVoice] {
        let normalized = languageCode.lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let language = voice.language.lowercased()
                if normalized == "pt-br" {
                    return language.hasPrefix("pt-br")
                }
                return language.hasPrefix(normalized)
            }
            .sorted { v1, v2 in
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    private override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    /// Speak text (single-shot: replaces anything currently playing).
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking || synthesizer.isPaused {
            stop()
        }

        enqueue(trimmed)
    }

    func beginStreaming() {
        stop()
        streamingActive = true
        isSpeaking = true
        onSpeechStarted?()
    }

    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    func endStreaming() {
        streamingActive = false
        if pendingUtterances == 0 {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        pendingUtterances += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        streamingActive = false
        pendingUtterances = 0
        isSpeaking = false
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            MetricsCollector.shared.markFirstAudio()
            DiagnosticLogger.shared.log("Latency", "Apple TTS first audible frame")
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStarted?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 && !self.streamingActive {
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 {
                self.streamingActive = false
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }
}
