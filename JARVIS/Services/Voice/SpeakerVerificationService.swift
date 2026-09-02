// JARVIS - SpeakerVerificationService.swift
// Local speaker enrollment/verification with FluidAudio CAM++ embeddings.
// Voice embeddings and raw enrollment audio never leave the iPhone.

import AVFoundation
import Foundation
import FluidAudio

final class SpeakerVerificationService: @unchecked Sendable {
    static let shared = SpeakerVerificationService()

    struct OwnerProfile: Codable {
        let id: UUID
        var name: String
        var embedding: [Float]
        var sampleCount: Int
        let createdAt: Date
        var updatedAt: Date
    }

    struct VerificationResult {
        let isMatch: Bool
        let similarity: Float?
        let reason: String
    }

    private let sampleRate = 16_000.0
    private let maxRecentSamples = 16_000 * 8
    private let lock = NSLock()
    private var recentSamples: [Float] = []
    private var profile: OwnerProfile?
    private let profileURL: URL
    private let embeddingEngine = SpeakerEmbeddingEngine()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        profileURL = docs.appendingPathComponent("jarvis_owner_voice_v1.json")
        profile = Self.loadProfile(from: profileURL)
    }

    var hasOwnerProfile: Bool {
        lock.lock(); defer { lock.unlock() }
        return profile != nil
    }

    var ownerProfileName: String? {
        lock.lock(); defer { lock.unlock() }
        return profile?.name
    }

    var ownerSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return profile?.sampleCount ?? 0
    }

    func feed(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        if channelCount <= 1 {
            mono = Array(UnsafeBufferPointer(start: channels[0], count: count))
        } else {
            for i in 0..<count {
                var sum: Float = 0
                for ch in 0..<channelCount { sum += channels[ch][i] }
                mono[i] = sum / Float(channelCount)
            }
        }

        let samples = Self.resample(
            mono,
            from: buffer.format.sampleRate,
            to: sampleRate
        )
        append(samples)
    }

    func feedPCM16(_ data: Data) {
        guard data.count >= 2 else { return }
        let samples: [Float] = data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int16.self)
            return words.map { Float(Int16(littleEndian: $0)) / Float(Int16.max) }
        }
        append(samples)
    }

    func resetRecentAudio() {
        lock.lock()
        recentSamples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func snapshotRecentAudio(maxSeconds: Double = 5.0) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let maxCount = min(recentSamples.count, Int(sampleRate * maxSeconds))
        return Array(recentSamples.suffix(maxCount))
    }

    func enrollRecentVoice(name: String) async -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.isEmpty ? (ownerProfileName ?? "Proprietário") : cleanName
        let raw = snapshotRecentAudio(maxSeconds: 6.0)

        guard let speech = Self.prepareSpeech(raw, minimumSeconds: 1.5) else {
            return "Não consegui uma amostra de voz longa e clara o suficiente. Fale por pelo menos dois segundos e tente novamente."
        }

        do {
            let newEmbedding = try await embeddingEngine.embedding(for: speech)
            let updated: OwnerProfile

            lock.lock()
            if var existing = profile {
                let previousWeight = Float(max(existing.sampleCount, 1))
                var averaged = zip(existing.embedding, newEmbedding).map {
                    (($0.0 * previousWeight) + $0.1) / (previousWeight + 1)
                }
                averaged = Self.l2Normalize(averaged)
                existing.name = displayName
                existing.embedding = averaged
                existing.sampleCount += 1
                existing.updatedAt = Date()
                updated = existing
            } else {
                updated = OwnerProfile(
                    id: UUID(),
                    name: displayName,
                    embedding: newEmbedding,
                    sampleCount: 1,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            }
            profile = updated
            lock.unlock()

            try Self.saveProfile(updated, to: profileURL)
            log("Enrollment saved samples=\(updated.sampleCount)")
            if updated.sampleCount < 3 {
                return "Amostra \(updated.sampleCount) salva para \(updated.name). Para melhorar a precisão, cadastre sua voz mais \(3 - updated.sampleCount) vez(es), falando frases diferentes."
            }
            return "Perfil de voz de \(updated.name) atualizado com \(updated.sampleCount) amostras. A validação por voz está pronta para testes."
        } catch {
            log("Enrollment failed: \(error.localizedDescription)")
            return "Não consegui gerar o perfil de voz: \(error.localizedDescription)"
        }
    }

    /// Preload CAM++ so the first protected command does not pay model-load latency.
    func warmUp() async {
        let started = Date()
        do {
            try await embeddingEngine.warmUp()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("CAM++ warm-up ready in \(ms)ms")
        } catch {
            log("CAM++ warm-up failed: \(error.localizedDescription)")
        }
    }

    func verifyRecentVoice(threshold: Float) async -> VerificationResult {
        let started = Date()
        let samples = snapshotRecentAudio(maxSeconds: 4.0)
        let result = await verify(samples: samples, threshold: threshold)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log(String(format: "Manual verify duration=%dms audio=%.2fs", ms, Double(samples.count) / 16_000.0))
        return result
    }

    func verify(samples raw: [Float], threshold: Float) async -> VerificationResult {
        let saved: OwnerProfile?
        lock.lock()
        saved = profile
        lock.unlock()

        guard let saved else {
            return VerificationResult(isMatch: false, similarity: nil, reason: "no_owner_profile")
        }
        // Commands can be short ("sim", "abra X"), so verification accepts a shorter sample
        // than enrollment. Very short utterances may still be rejected rather than weakening auth.
        guard let speech = Self.prepareSpeech(raw, minimumSeconds: 0.55) else {
            return VerificationResult(isMatch: false, similarity: nil, reason: "insufficient_speech")
        }

        do {
            let candidate = try await embeddingEngine.embedding(for: speech)
            let similarity = CampPlusEmbedder.cosine(saved.embedding, candidate)
            let match = similarity >= threshold
            log(String(format: "Verify match=%@ similarity=%.3f threshold=%.3f", match ? "yes" : "no", similarity, threshold))
            return VerificationResult(
                isMatch: match,
                similarity: similarity,
                reason: match ? "match" : "speaker_mismatch"
            )
        } catch {
            log("Verification failed: \(error.localizedDescription)")
            return VerificationResult(isMatch: false, similarity: nil, reason: "model_error")
        }
    }

    func forgetOwnerProfile() {
        lock.lock()
        profile = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: profileURL)
        log("Owner profile deleted")
    }

    private func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        recentSamples.append(contentsOf: samples)
        if recentSamples.count > maxRecentSamples {
            recentSamples.removeFirst(recentSamples.count - maxRecentSamples)
        }
        lock.unlock()
    }

    private static func prepareSpeech(_ samples: [Float], minimumSeconds: Double) -> [Float]? {
        let frame = 320
        let minimumSamples = max(frame * 2, Int(16_000.0 * minimumSeconds))
        guard samples.count >= minimumSamples else { return nil }

        var firstActive: Int?
        var lastActive: Int?
        var i = 0
        while i + frame <= samples.count {
            let slice = samples[i..<(i + frame)]
            let rms = sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame))
            if rms >= 0.008 {
                if firstActive == nil { firstActive = i }
                lastActive = i + frame
            }
            i += frame
        }

        guard let first = firstActive, let last = lastActive else { return nil }
        let pad = 1_600
        let start = max(0, first - pad)
        let end = min(samples.count, last + pad)
        guard end - start >= minimumSamples else { return nil }

        let clipped = Array(samples[start..<end].suffix(16_000 * 6))
        let rms = sqrt(clipped.reduce(Float(0)) { $0 + $1 * $1 } / Float(clipped.count))
        guard rms >= 0.006 else { return nil }
        return clipped
    }

    private static func l2Normalize(_ values: [Float]) -> [Float] {
        let norm = max(sqrt(values.reduce(Float(0)) { $0 + $1 * $1 }), 1e-9)
        return values.map { $0 / norm }
    }

    private static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        guard !input.isEmpty, source > 0, target > 0 else { return [] }
        if abs(source - target) < 1 { return input }

        let ratio = source / target
        let count = max(1, Int(Double(input.count) / ratio))
        var output = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let index = Int(position)
            let fraction = Float(position - Double(index))
            if index + 1 < input.count {
                output[i] = input[index] * (1 - fraction) + input[index + 1] * fraction
            } else if index < input.count {
                output[i] = input[index]
            }
        }
        return output
    }

    private static func loadProfile(from url: URL) -> OwnerProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OwnerProfile.self, from: data)
    }

    private static func saveProfile(_ profile: OwnerProfile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    private func log(_ message: String) {
        Task { @MainActor in
            DiagnosticLogger.shared.log("VoiceAuth", message)
        }
    }
}

private actor SpeakerEmbeddingEngine {
    private var embedder: CampPlusEmbedder?

    func warmUp() async throws {
        if embedder == nil {
            embedder = try await CampPlusEmbedder.load()
        }
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        if embedder == nil {
            embedder = try await CampPlusEmbedder.load()
        }
        guard let embedder else {
            throw SpeakerVerificationError.modelUnavailable
        }
        return try await embedder.embed(audio: samples)
    }
}

enum SpeakerVerificationError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        "Modelo de reconhecimento de voz indisponível."
    }
}
