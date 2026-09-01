// JARVIS - PhoneCameraService.swift
// One-shot iPhone camera capture for vision/face tools. Video-only: never takes ownership of audio.

import AVFoundation
import UIKit

final class PhoneCameraService: NSObject {
    static let shared = PhoneCameraService()

    enum CameraError: LocalizedError {
        case permissionDenied
        case unavailable
        case configurationFailed
        case busy
        case captureFailed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Acesso à câmera do iPhone não foi autorizado."
            case .unavailable:
                return "Nenhuma câmera do iPhone está disponível."
            case .configurationFailed:
                return "Não foi possível configurar a câmera do iPhone."
            case .busy:
                return "A câmera do iPhone já está sendo usada por outra captura."
            case .captureFailed:
                return "A câmera do iPhone não conseguiu gerar a foto."
            case .timedOut:
                return "A captura da câmera do iPhone demorou demais."
            }
        }
    }

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "jarvis.phone-camera.session", qos: .userInitiated)

    private var activeCaptureID: UUID?
    private var activeDelegate: PhotoCaptureDelegate?

    private override init() {
        super.init()
        // We only attach video. Explicitly keep AVCaptureSession away from the JARVIS audio session
        // so Gemini Live / wake-word microphone ownership is not reconfigured by a face photo.
        session.automaticallyConfiguresApplicationAudioSession = false
    }

    func capturePhoto(position: AVCaptureDevice.Position = .back) async throws -> UIImage {
        guard await requestCameraAccessIfNeeded() else {
            log("Permission denied")
            throw CameraError.permissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                guard self.activeCaptureID == nil else {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }

                do {
                    try self.configureSession(position: position)
                } catch {
                    self.log("Configuration failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }

                let captureID = UUID()
                self.activeCaptureID = captureID

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    guard let self else {
                        continuation.resume(with: result)
                        return
                    }
                    self.finishCapture(id: captureID, result: result, continuation: continuation)
                }
                self.activeDelegate = delegate

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .speed
                self.log("Capturing one-shot photo position=\(position == .front ? "front" : "back")")
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)

                self.sessionQueue.asyncAfter(deadline: .now() + 6) { [weak self, weak delegate] in
                    guard let self, self.activeCaptureID == captureID else { return }
                    delegate?.finish(.failure(CameraError.timedOut))
                }
            }
        }
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw CameraError.unavailable }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .speed
    }

    private func finishCapture(
        id: UUID,
        result: Result<UIImage, Error>,
        continuation: CheckedContinuation<UIImage, Error>
    ) {
        sessionQueue.async { [weak self] in
            guard let self, self.activeCaptureID == id else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.activeCaptureID = nil
            self.activeDelegate = nil

            switch result {
            case .success(let image):
                self.log("Photo captured size=\(Int(image.size.width))x\(Int(image.size.height))")
            case .failure(let error):
                self.log("Capture failed: \(error.localizedDescription)")
            }
            continuation.resume(with: result)
        }
    }

    private func log(_ message: String) {
        Task { @MainActor in
            DiagnosticLogger.shared.log("PhoneCamera", message)
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let lock = NSLock()
    private var completion: ((Result<UIImage, Error>) -> Void)?

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            finish(.failure(PhoneCameraService.CameraError.captureFailed))
            return
        }
        finish(.success(image))
    }

    func finish(_ result: Result<UIImage, Error>) {
        lock.lock()
        guard let callback = completion else {
            lock.unlock()
            return
        }
        completion = nil
        lock.unlock()
        callback(result)
    }
}
