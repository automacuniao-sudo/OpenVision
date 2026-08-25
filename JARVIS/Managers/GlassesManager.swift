// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via DAT SDK 0.9

import Foundation
import SwiftUI
import CoreMedia
import OSLog
import MWDATCore
import MWDATCamera

/// Manages Meta smart-glasses registration, connection, DAT developer component, and camera stream.
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    @Published var isRegistered: Bool = false
    @Published var connectedDevice: DeviceIdentifier?
    @Published var connectedDeviceCount: Int = 0
    @Published var isStreaming: Bool = false
    @Published var lastFrame: UIImage?
    private(set) var lastFrameTime: Date = .distantPast
    @Published var lastPhotoData: Data?
    @Published var errorMessage: String?

    // MARK: - DAT 0.9 lifecycle

    private let wearables = Wearables.shared
    private var deviceSession: DeviceSession?
    private var camera: Camera?

    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    var onVideoFrame: ((UIImage) -> Void)?
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Initialization

    private init() {
        log("Initializing DAT manager")
        setupRegistrationListener()
        setupDevicesListener()
    }

    // MARK: - Registration

    func register() async throws {
        log("Starting registration")

        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                isRegistered = true
                log("Already registered")
                return
            }
            break
        }

        try await wearables.startRegistration()
        log("Registration initiated; waiting for Meta AI callback")
    }

    func unregister() async {
        log("Starting unregistration")

        if isStreaming {
            await stopStreaming()
        }

        do {
            try await wearables.startUnregistration()
            isRegistered = false
            connectedDevice = nil
            connectedDeviceCount = 0
            errorMessage = nil
            log("Unregistration successful")
        } catch {
            errorMessage = "Unregister failed: \(error.localizedDescription)"
            log("Unregistration error: \(error.localizedDescription)")
        }
    }

    /// Ask Meta AI to stage/update the DAT developer component on the glasses. This is required on
    /// devices where registration is valid but the on-glasses developer app/DWA is missing.
    func installOrUpdateGlassesApp() async {
        do {
            log("Opening DAT glasses app update flow")
            try await wearables.openDATGlassesAppUpdate()
            log("DAT glasses app update hand-off opened")
        } catch {
            errorMessage = "Glasses app update hand-off failed: \(error.localizedDescription)"
            log("DAT glasses app update hand-off failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming

    func startStreaming() async {
        guard isRegistered else {
            errorMessage = "Not registered with Meta AI"
            log("Cannot start streaming: not registered")
            return
        }

        guard !isStreaming else {
            log("Already streaming")
            return
        }

        guard let deviceId = connectedDevice else {
            errorMessage = "No glasses connected"
            log("Cannot start streaming: no connected device")
            return
        }

        errorMessage = nil
        log("Starting camera stream device=\(deviceId)")

        // Ask the SDK for its compatibility verdict before opening a session. This gives us a useful
        // diagnosis for firmware/SDK mismatch instead of only an opaque "Device unavailable".
        if let device = wearables.deviceForIdentifier(deviceId) {
            let compatibility = device.compatibility()
            log("Device type=\(device.deviceType()) link=\(device.linkState) compatibility=\(compatibility)")
            if compatibility == .deviceUpdateRequired {
                errorMessage = "Glasses firmware update required — update them in the Meta AI app"
            } else if compatibility == .sdkUpdateRequired {
                errorMessage = "Glasses are newer than the installed Meta DAT SDK"
            }
        } else {
            log("deviceForIdentifier returned nil for \(deviceId)")
        }

        // Camera permission is controlled by the Meta Wearables registration, not only iOS camera
        // permission. Request it before creating the device/camera session.
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            log("Camera permission status=\(status)")

            if status != .granted {
                status = try await wearables.requestPermission(.camera)
                log("Camera permission after request=\(status)")
            }

            guard status == .granted else {
                errorMessage = "Camera permission denied"
                log("Camera permission not granted")
                return
            }
        } catch {
            errorMessage = "Permission error: \(error.localizedDescription)"
            log("Camera permission error: \(error.localizedDescription)")
            return
        }

        let selector = SpecificDeviceSelector(device: deviceId)
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 30
        )

        do {
            let session = try wearables.createSession(deviceSelector: selector)
            deviceSession = session

            // DAT 0.9 ordering is critical: start DeviceSession and wait for .started BEFORE
            // addCamera. Calling addCamera on an idle session can simply return nil.
            let stateStream = session.stateStream()
            let sessionErrorTask = Task {
                for await error in session.errorStream() {
                    await MainActor.run {
                        self.errorMessage = "Session error: \(error.description)"
                        self.log("Device session error: \(error.description)")
                    }
                }
            }
            defer { sessionErrorTask.cancel() }

            log("Starting DeviceSession")
            try session.start()

            let started = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await state in stateStream {
                        await MainActor.run {
                            self.log("DeviceSession state=\(state)")
                        }
                        if state == .started { return true }
                        if state == .stopped { return false }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return false
                }

                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            guard started else {
                errorMessage = "Device session did not start (timeout or device rejected session)"
                log("DeviceSession failed to reach .started")
                dumpSDKLogs(since: 30)
                session.stop()
                deviceSession = nil
                return
            }

            guard let attachedCamera = try session.addCamera(config: config) else {
                errorMessage = "Failed to attach camera to device session"
                log("DeviceSession.addCamera returned nil")
                dumpSDKLogs(since: 30)
                session.stop()
                deviceSession = nil
                return
            }

            camera = attachedCamera
            setupStreamListeners(stream: attachedCamera.stream)
            attachedCamera.stream.start()
            isStreaming = true
            log("Streaming started successfully")
        } catch {
            errorMessage = "Stream start failed: \(error.localizedDescription)"
            log("Stream start error: \(error.localizedDescription)")
            dumpSDKLogs(since: 30)
            cleanupStreamListeners()
            camera = nil
            deviceSession?.stop()
            deviceSession = nil
            isStreaming = false
        }
    }

    func stopStreaming() async {
        guard isStreaming || camera != nil || deviceSession != nil else { return }

        log("Stopping camera stream")
        camera?.stop()
        deviceSession?.stop()

        cleanupStreamListeners()
        camera = nil
        deviceSession = nil
        isStreaming = false
        lastFrame = nil
        lastFrameTime = .distantPast
        log("Streaming stopped")
    }

    func capturePhoto() async {
        guard isStreaming, let stream = camera?.stream else {
            errorMessage = "Streaming must be active to capture photos"
            return
        }

        log("Capturing photo")
        // DAT 0.9 capturePhoto is non-throwing; async failures are published by stream.errorPublisher.
        if !stream.capturePhoto(format: .jpeg) {
            errorMessage = "Failed to start photo capture"
            log("capturePhoto returned false")
        }
    }

    // MARK: - Listeners

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        self.log("Registration state=registered")
                    } else {
                        self.isRegistered = false
                        self.log("Registration state=\(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    self.log("Devices updated count=\(devices.count) first=\(String(describing: devices.first))")
                }
            }
        }
    }

    private func setupStreamListeners(stream: MWDATCamera.Stream) {
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.log("Camera stream state=\(state)")
                switch state {
                case .streaming:
                    self?.isStreaming = true
                case .stopped:
                    self?.isStreaming = false
                default:
                    break
                }
            }
        }

        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.onVideoSampleBuffer?(frame.sampleBuffer)
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.lastFrameTime = Date()
                    self?.onVideoFrame?(image)
                }
            }
        }

        photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                self?.log("Photo captured bytes=\(data.count)")
            }
        }

        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                // DAT's raw-video codec is expected to pause when the app is inactive/screen-locked.
                // Do not throw a scary modal for that expected lifecycle event; keep it in logs.
                if UIApplication.shared.applicationState == .active {
                    self?.errorMessage = error.localizedDescription
                }
                self?.log("Camera stream error: \(error.localizedDescription)")
            }
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }

    // MARK: - Diagnostics

    /// DAT writes teardown details to OSLog. Dump our process's non-Apple entries when session
    /// startup fails so field logs contain the real SDK reason (DWA missing, manifest, device, etc.).
    private func dumpSDKLogs(since seconds: TimeInterval) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            let entries = try store.getEntries(at: position)
            log("===== Meta DAT SDK log dump last \(Int(seconds))s =====")
            for entry in entries {
                guard let item = entry as? OSLogEntryLog else { continue }
                let subsystem = item.subsystem
                guard !subsystem.isEmpty, !subsystem.hasPrefix("com.apple") else { continue }
                print("[SDKLOG] \(subsystem)/\(item.category) [\(item.level.rawValue)] \(item.composedMessage)")
            }
            log("===== end Meta DAT SDK log dump =====")
        } catch {
            log("OSLogStore dump failed: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        print("[GlassesManager] \(message)")
        DiagnosticLogger.shared.log("MetaDAT", message)
    }
}
