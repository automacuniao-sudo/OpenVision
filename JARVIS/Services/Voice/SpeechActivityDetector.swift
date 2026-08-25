// OpenVision - SpeechActivityDetector.swift
// Acoustic voice-activity detection (Silero VAD via CoreML) for JARVIS end-of-turn.
//
// SFSpeechRecognizer partials arrive in bursts and are not a reliable acoustic silence signal.
// This detector listens to the actual mic stream and reports speech start/end. Failure is soft:
// if FluidAudio/Silero cannot initialize, VoiceCommandService keeps its existing timer fallback.

import AVFoundation
import Foundation
import FluidAudio

/// Detects when speech starts and stops in the live microphone stream.
/// Events are delivered on the main actor; audio buffers are fed from the Core Audio render thread.
final class SpeechActivityDetector: @unchecked Sendable {

    // MARK: - Events

    var onSpeechStart: (@MainActor () -> Void)?
    var onSpeechEnd: (@MainActor () -> Void)?

    // MARK: - State

    private(set) var isAvailable = false

    private let lock = NSLock()
    private var pending: [Float] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var vad: VadManager?
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?

    /// Silero target: 16 kHz mono Float32, processed in FluidAudio's streaming chunk size.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(VadManager.sampleRate),
        channels: 1,
        interleaved: false
    )

    // MARK: - Lifecycle

    func start() async {
        guard consumerTask == nil else { return }

        let manager: VadManager
        do {
            // Conservative threshold for phone/glasses microphones: a false speech event only adds
            // latency; a false silence event can cut the user's sentence.
            manager = try await VadManager(config: VadConfig(defaultThreshold: 0.9))
        } catch {
            print("[VAD] Unavailable; keeping timer fallback: \(error)")
            await MainActor.run {
                DiagnosticLogger.shared.log("VAD", "Unavailable; timer fallback: \(error.localizedDescription)")
            }
            isAvailable = false
            return
        }

        vad = manager
        isAvailable = true
        print("[VAD] Ready — acoustic end-of-turn active")
        await MainActor.run {
            DiagnosticLogger.shared.log("VAD", "Ready threshold=0.9 sampleRate=\(VadManager.sampleRate)")
        }

        let (stream, continuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        chunks = continuation

        consumerTask = Task { [weak self] in
            var state = await manager.makeStreamState()
            for await chunk in stream {
                guard !Task.isCancelled else { break }
                do {
                    let result = try await manager.processStreamingChunk(chunk, state: state)
                    state = result.state
                    if let event = result.event {
                        await self?.deliver(event)
                    }
                } catch {
                    print("[VAD] Chunk failed: \(error)")
                }
            }
        }
    }

    func stop() {
        chunks?.finish()
        chunks = nil
        consumerTask?.cancel()
        consumerTask = nil
        vad = nil
        isAvailable = false

        lock.lock()
        pending.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    /// Drop audio/converter state after a mic route change or recognition restart.
    func reset() {
        lock.lock()
        pending.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    // MARK: - Audio input

    /// Called from the Core Audio render thread. Keep this path small and never hop to main actor.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isAvailable, let targetFormat else { return }
        guard let converted = convert(buffer, to: targetFormat) else { return }

        var ready: [[Float]] = []
        lock.lock()
        pending.append(contentsOf: converted)
        while pending.count >= VadManager.chunkSize {
            ready.append(Array(pending.prefix(VadManager.chunkSize)))
            pending.removeFirst(VadManager.chunkSize)
        }
        lock.unlock()

        for chunk in ready {
            chunks?.yield(chunk)
        }
    }

    // MARK: - Private

    @MainActor
    private func deliver(_ event: VadStreamEvent) {
        switch event.kind {
        case .speechStart:
            DiagnosticLogger.shared.log("VAD", "speechStart")
            onSpeechStart?()
        case .speechEnd:
            DiagnosticLogger.shared.log("VAD", "speechEnd")
            onSpeechEnd?()
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> [Float]? {
        lock.lock()
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil,
              out.frameLength > 0,
              let channel = out.floatChannelData?[0] else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
