// JARVIS - VisionCaptureService.swift
// Chooses the best camera source for one-shot vision work: Ray-Ban POV first, iPhone fallback.

import UIKit

@MainActor
final class VisionCaptureService {
    static let shared = VisionCaptureService()

    enum CaptureSource: String {
        case automatic = "auto"
        case glasses
        case phone
    }

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

    private init() {}

    func captureImage(
        preferred source: CaptureSource = .automatic,
        keepGlassesStreaming: Bool = false
    ) async throws -> CapturedImage {
        switch source {
        case .glasses:
            guard let image = await captureFromGlasses(keepStreaming: keepGlassesStreaming) else {
                throw CaptureError.glassesUnavailable
            }
            DiagnosticLogger.shared.log("Vision", "Captured image source=glasses")
            return CapturedImage(image: image, source: .glasses)

        case .phone:
            let image = try await PhoneCameraService.shared.capturePhoto()
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone")
            return CapturedImage(image: image, source: .phone)

        case .automatic:
            if GlassesManager.shared.isRegistered,
               GlassesManager.shared.connectedDevice != nil,
               let image = await captureFromGlasses(keepStreaming: keepGlassesStreaming) {
                DiagnosticLogger.shared.log("Vision", "Captured image source=glasses")
                return CapturedImage(image: image, source: .glasses)
            }

            DiagnosticLogger.shared.log("Vision", "Glasses unavailable; falling back to iPhone camera")
            let image = try await PhoneCameraService.shared.capturePhoto()
            DiagnosticLogger.shared.log("Vision", "Captured image source=phone")
            return CapturedImage(image: image, source: .phone)
        }
    }

    private func captureFromGlasses(keepStreaming: Bool) async -> UIImage? {
        let glasses = GlassesManager.shared
        guard glasses.isRegistered, glasses.connectedDevice != nil else { return nil }

        let wasStreaming = glasses.isStreaming
        if !glasses.isStreaming {
            await glasses.startStreaming()
        }
        guard glasses.isStreaming else { return nil }

        // Require a fresh frame rather than reusing a stale image from an earlier stream.
        glasses.lastFrame = nil
        var frame: UIImage?
        for _ in 0..<40 { // up to ~4 seconds
            if let current = glasses.lastFrame {
                frame = current
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if frame == nil && !wasStreaming && glasses.isStreaming {
            await glasses.stopStreaming()
        } else if !keepStreaming && glasses.isStreaming {
            await glasses.stopStreaming()
        }

        return frame
    }
}
