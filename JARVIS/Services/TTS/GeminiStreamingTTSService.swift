// JARVIS - GeminiStreamingTTSService.swift
// Low-latency streaming TTS for text backends, sharing Gemini Live's configured voice.

import Foundation

@MainActor
final class GeminiStreamingTTSService: ObservableObject {
    static let shared = GeminiStreamingTTSService()

    @Published private(set) var isSpeaking = false

    var onSpeechStarted: (() -> Void)?
    var onSpeechEnded: (() -> Void)?

    private let playback = AudioPlaybackService()
    private var playbackReady = false

    private var pendingText: [String] = []
    private var drainTask: Task<Void, Never>?
    private var streamingActive = false
    private var generation = 0

    private var apiKey: String {
        SettingsManager.shared.settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var voiceName: String {
        let configured = SettingsManager.shared.settings.geminiVoiceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "Charon" : configured
    }

    private init() {
        playback.inputSampleRate = 24_000
        playback.onPlaybackComplete = { [weak self] in
            self?.finishIfReady()
        }
    }

    func beginStreaming() {
        generation += 1
        drainTask?.cancel()
        drainTask = nil
        pendingText.removeAll()
        playback.stop()
        streamingActive = true
        ensurePlaybackReady()
        setSpeaking(true)
        DiagnosticLogger.shared.log("GeminiTTS", "Streaming session begin voice=\(voiceName)")
    }

    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !streamingActive {
            beginStreaming()
        }
        pendingText.append(trimmed)
        startDrainIfNeeded()
    }

    func endStreaming() {
        streamingActive = false
        DiagnosticLogger.shared.log("GeminiTTS", "Streaming session end requested")
        finishIfReady()
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        beginStreaming()
        speakChunk(trimmed)
        endStreaming()
    }

    func stop() {
        generation += 1
        drainTask?.cancel()
        drainTask = nil
        pendingText.removeAll()
        streamingActive = false
        playback.stop()
        setSpeaking(false)
        DiagnosticLogger.shared.log("GeminiTTS", "Stopped / queue cleared")
    }

    private func ensurePlaybackReady() {
        guard !playbackReady else { return }
        do {
            try playback.setup()
            playback.inputSampleRate = 24_000
            playbackReady = true
        } catch {
            DiagnosticLogger.shared.log("GeminiTTS", "Playback setup failed: \(error.localizedDescription)")
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        let runGeneration = generation

        drainTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, runGeneration == self.generation {
                guard !self.pendingText.isEmpty else { break }
                let text = self.pendingText.removeFirst()

                do {
                    try await self.streamSpeech(text, generation: runGeneration)
                } catch is CancellationError {
                    return
                } catch {
                    DiagnosticLogger.shared.log("GeminiTTS", "Chunk failed: \(error.localizedDescription)")
                }
            }

            guard runGeneration == self.generation else { return }
            self.drainTask = nil
            self.finishIfReady()
        }
    }

    private func streamSpeech(_ text: String, generation runGeneration: Int) async throws {
        guard !apiKey.isEmpty else { throw GeminiStreamingTTSError.notConfigured }
        ensurePlaybackReady()
        guard playbackReady else { throw GeminiStreamingTTSError.playbackUnavailable }

        // Gemini TTS preview can occasionally return a transient 500; official docs recommend retry.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await performStreamingRequest(text, generation: runGeneration)
                return
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                guard attempt == 1 else { break }
                DiagnosticLogger.shared.log("GeminiTTS", "Retrying chunk once: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
        throw lastError ?? GeminiStreamingTTSError.invalidResponse
    }

    private func performStreamingRequest(_ text: String, generation runGeneration: Int) async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw GeminiStreamingTTSError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        request.timeoutInterval = 30

        let prompt = """
        Synthesize speech in natural Brazilian Portuguese. Read ONLY the transcript below exactly,
        without adding introductions, explanations, labels, or quotation marks. Keep the delivery
        concise, calm, natural, and conversational like JARVIS.
        TRANSCRIPT:
        \(text)
        """

        let body: [String: Any] = [
            "model": "gemini-3.1-flash-tts-preview",
            "input": prompt,
            "response_format": ["type": "audio"],
            "generation_config": [
                "speech_config": [
                    ["voice": voiceName]
                ]
            ],
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiStreamingTTSError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw GeminiStreamingTTSError.httpStatus(http.statusCode)
        }

        var audioChunkCount = 0

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            guard runGeneration == generation else { throw CancellationError() }

            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let jsonText: String
            if trimmed.hasPrefix("data:") {
                jsonText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                jsonText = trimmed
            }

            guard jsonText != "[DONE]",
                  let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let eventType = (object["event_type"] as? String) ?? (object["eventType"] as? String),
                  eventType == "step.delta",
                  let delta = object["delta"] as? [String: Any],
                  (delta["type"] as? String) == "audio",
                  let base64 = delta["data"] as? String,
                  let pcm = Data(base64Encoded: base64),
                  !pcm.isEmpty
            else { continue }

            if audioChunkCount == 0 {
                DiagnosticLogger.shared.log("GeminiTTS", "First PCM chunk bytes=\(pcm.count) voice=\(voiceName)")
            }
            audioChunkCount += 1
            playback.playAudio(data: pcm)
        }

        guard audioChunkCount > 0 else {
            throw GeminiStreamingTTSError.noAudio
        }
    }

    private func finishIfReady() {
        guard !streamingActive,
              pendingText.isEmpty,
              drainTask == nil,
              !playback.isPlaying
        else { return }

        setSpeaking(false)
        DiagnosticLogger.shared.log("GeminiTTS", "Playback drained / stream complete")
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        if value {
            onSpeechStarted?()
        } else {
            onSpeechEnded?()
        }
    }
}

enum GeminiStreamingTTSError: LocalizedError {
    case notConfigured
    case playbackUnavailable
    case invalidResponse
    case httpStatus(Int)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gemini API key is not configured for streaming voice."
        case .playbackUnavailable:
            return "Streaming voice playback is unavailable."
        case .invalidResponse:
            return "Invalid Gemini TTS response."
        case .httpStatus(let status):
            return "Gemini TTS HTTP \(status)."
        case .noAudio:
            return "Gemini TTS returned no audio."
        }
    }
}
