// JARVIS - VisionCaptureService.swift
// Chooses the best camera source for one-shot vision work: Ray-Ban POV first, iPhone fallback.

import UIKit

@MainActor
final class VisionCaptureService {
    static let shared = VisionCaptureService()

    typealias CaptureSource = CameraPolicy.Source

    struct CapturedImage {
        let image: UIImage
        let source: CaptureSource
    }

    enum CaptureError: LocalizedError {
        case glassesUnavailable
        case noCameraImage

        var errorDescription: String? {
            switch self {
            case .glassesUnavailable:
                return "Os Ray-Ban não estão conectados ou não forneceram uma imagem."
            case .noCameraImage:
                return "Não foi possível capturar uma imagem."
            }
        }
    }

    private var captureInProgress = false
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func captureImage(
        preferred source: CaptureSource = .automatic,
        keepGlassesStreaming: Bool = false
    ) async throws -> CapturedImage {
        if captureInProgress {
            await withCheckedContinuation { captureWaiters.append($0) }
        } else { captureInProgress = true }
        defer {
            if captureWaiters.isEmpty { captureInProgress = false }
            else { captureWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        switch source {
        case .phone:
            let image = try await PhoneCameraService.shared.capturePhoto(position: .back)
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone_back")
            return CapturedImage(image: image, source: .phone)

        case .phoneFront:
            let image = try await PhoneCameraService.shared.capturePhoto(position: .front)
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone_front")
            return CapturedImage(image: image, source: .phoneFront)

        case .phoneBack:
            let image = try await PhoneCameraService.shared.capturePhoto(position: .back)
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone_back")
            return CapturedImage(image: image, source: .phoneBack)

        case .automatic, .glasses:
            if GlassesManager.shared.isRegistered,
               GlassesManager.shared.connectedDevice != nil,
               let image = await captureFromGlasses(keepStreaming: keepGlassesStreaming) {
                DiagnosticLogger.shared.log("Vision", "Captured image source=glasses")
                return CapturedImage(image: image, source: .glasses)
            }

            try Task.checkCancellation()
            DiagnosticLogger.shared.log("Vision", "Glasses unavailable; falling back to iPhone camera")
            let image = try await PhoneCameraService.shared.capturePhoto(position: .back)
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone_back")
            return CapturedImage(image: image, source: .phone)
        }
    }

    private func captureFromGlasses(keepStreaming: Bool) async -> UIImage? {
        let glasses = GlassesManager.shared
        guard glasses.isRegistered, glasses.connectedDevice != nil else { return nil }

        // A tool borrows an existing session. It must never clear its shared frame or stop it.
        let startedHere = !glasses.hasCameraSession
        let requestedAt = Date()
        let generation: UUID
        if startedHere {
            guard let startedGeneration = await glasses.startStreaming() else { return nil }
            generation = startedGeneration
        } else { generation = glasses.streamGeneration }
        guard glasses.hasCameraSession, glasses.streamGeneration == generation else { return nil }

        var image: UIImage?
        // Readiness is separate from frame delivery: start() requested is not .streaming.
        for _ in 0..<40 {
            if glasses.isCameraReady || Task.isCancelled || !glasses.hasCameraSession || glasses.streamGeneration != generation { break }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        if glasses.isCameraReady && !Task.isCancelled && glasses.streamGeneration == generation {
            // Request a fresh still as well: some firmware delivers JPEG photos while raw
            // frame conversion fails. Do not reuse/clear another consumer's cached photo.
            if glasses.lastFrameTime.timeIntervalSince(requestedAt) < -1 {
                await glasses.capturePhoto()
            }
            for _ in 0..<40 {
                if Task.isCancelled || !glasses.hasCameraSession || glasses.streamGeneration != generation { break }
                if glasses.lastFrameTime >= requestedAt, let frame = glasses.lastFrame {
                    image = frame
                    break
                }
                if glasses.lastPhotoTime >= requestedAt, let data = glasses.lastPhotoData,
                   let photo = UIImage(data: data) {
                    image = photo
                    break
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
        if CameraPolicy.shouldStopStream(startedHere: startedHere, keepStreaming: keepStreaming, sameSession: glasses.streamGeneration == generation),
           glasses.hasCameraSession { await glasses.stopStreaming() }
        DiagnosticLogger.shared.log("Vision", "Glasses capture ready=\(glasses.isCameraReady) image=\(image != nil) borrowed=\(!startedHere)")
        return image
    }
}
