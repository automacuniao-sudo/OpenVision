// JARVIS - OpenClawService.swift
// OpenClaw Gateway protocol v4 client with device pairing support.

import Combine
import Foundation
import Network
import UIKit

@MainActor
final class OpenClawService: ObservableObject {
    static let shared = OpenClawService()

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing = false
    @Published var currentToolName: String?
    @Published var isToolRunning = false
    @Published var lastError: String?
    @Published var debugInfo = ""

    var onAgentMessage: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?
    var onToolStatusChanged: ((String?, Bool) -> Void)?
    var onToolCall: ((String, [String: Any], @escaping (String) -> Void) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    private var gatewayURL: URL? {
        guard let raw = SettingsManager.shared.settings.openClawGatewayURL.nilIfEmpty,
              let url = URL(string: raw) else { return nil }
        return url
    }

    private var authToken: String {
        SettingsManager.shared.settings.openClawAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ConnectChallenge {
        let nonce: String
        let timestampMs: Int64
    }

    private let operatorScopes = ["operator.read", "operator.write"]
    private let clientId = "openclaw-ios"
    private let clientMode = "ui"
    private let role = "operator"

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var requestCounter = 0
    private var pendingRequests: [String: CheckedContinuation<OpenClawResponse, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var latestChallenge: ConnectChallenge?

    private var intentionalDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var hasConnectedBefore = false

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "jarvis.openclaw.network")
    private var isNetworkAvailable = true

    private var heartbeatTask: Task<Void, Never>?
    private var awaitingPong = false

    private var lifecycleObservers: [Any] = []
    private var wasConnectedBeforeSuspend = false
    private var accumulatedResponse = ""

    private static var sessionKey = "jarvis-\(UUID().uuidString.prefix(8))"

    private init() {
        setupNetworkMonitor()
        setupLifecycleObservers()
    }

    deinit {
        networkMonitor.cancel()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func transition(to newState: AIConnectionState) {
        let oldState = connectionState
        guard oldState != newState else { return }
        print("[OpenClaw] \(oldState.description) → \(newState.description)")
        connectionState = newState
        onConnectionStateChanged?(newState)

        switch newState {
        case .connected:
            hasConnectedBefore = true
            startHeartbeat()
        case .reconnecting(let attempt):
            stopHeartbeat()
            scheduleReconnect(attempt: attempt)
        case .disconnected:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.notConnected)
            onDisconnected?()
        case .suspended:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.notConnected)
        case .failed:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.connectionFailed)
            onDisconnected?()
        case .connecting:
            break
        }
    }

    func connect() async throws {
        guard gatewayURL != nil, !authToken.isEmpty else {
            throw AIBackendError.notConfigured
        }
        guard !connectionState.isUsable else {
            debugInfo = "Already connected"
            return
        }
        guard !connectionState.isAttempting else {
            debugInfo = "Connection in progress"
            return
        }

        intentionalDisconnect = false
        lastError = nil
        transition(to: .connecting)

        var lastErr: Error?
        for attempt in 1...3 {
            do {
                debugInfo = attempt > 1 ? "Retrying... (\(attempt)/3)" : "Connecting..."
                try await performConnect()
                return
            } catch {
                lastErr = error
                print("[OpenClaw] Connection attempt \(attempt) failed: \(error.localizedDescription)")
                // Pairing and authentication errors need user action; do not spam retries.
                if isPairingOrAuthError(error) { break }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        transition(to: .failed(lastErr?.localizedDescription ?? "Connection failed"))
        throw lastErr ?? AIBackendError.connectionFailed
    }

    private func performConnect() async throws {
        closeWebSocket()
        requestCounter = 0
        latestChallenge = nil
        failPendingRequests(error: AIBackendError.notConnected)

        guard let url = buildWebSocketURL() else { throw AIBackendError.notConfigured }
        debugInfo = "Opening \(url.host ?? "gateway")..."

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: config)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()
        startReceiving()

        var running = false
        for _ in 0..<50 {
            if webSocket?.state == .running {
                running = true
                break
            }
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard running else { throw AIBackendError.connectionTimeout }

        debugInfo = "Waiting for OpenClaw challenge..."
        let challenge = try await waitForChallenge()

        debugInfo = "Authenticating device..."
        try await sendHandshake(challenge: challenge)

        transition(to: .connected)
        debugInfo = "Connected to OpenClaw"
        print("[OpenClaw] Protocol v4 connected successfully")
    }

    func disconnect() async {
        guard connectionState != .disconnected else { return }
        intentionalDisconnect = true
        transition(to: .disconnected)
    }

    private func buildWebSocketURL() -> URL? {
        guard let gatewayURL,
              var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        // Current OpenClaw Gateway uses the root WebSocket endpoint. Do not append legacy /ws.
        if components.path == "/ws" { components.path = "" }
        // Authentication belongs in connect.params.auth, never in the URL query string.
        components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "token" }
        return components.url
    }

    private func waitForChallenge() async throws -> ConnectChallenge {
        for _ in 0..<60 {
            if let challenge = latestChallenge { return challenge }
            guard webSocket?.state == .running else { throw AIBackendError.notConnected }
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AIBackendError.requestFailed("OpenClaw did not send connect.challenge")
    }

    private func sendHandshake(challenge: ConnectChallenge) async throws {
        guard let gatewayURL else { throw AIBackendError.notConfigured }
        let identity = try JARVISOpenClawDeviceAuthStore.loadOrCreateIdentity()
        let savedDeviceToken = JARVISOpenClawDeviceAuthStore.loadDeviceToken(for: gatewayURL)
        let effectiveToken = savedDeviceToken ?? authToken
        guard !effectiveToken.isEmpty else { throw AIBackendError.notConfigured }

        let scopeString = operatorScopes.joined(separator: ",")
        // OpenClaw's current Swift client intentionally uses the compatible v2
        // signed payload while still negotiating wire protocol v4.
        let signaturePayload = [
            "v2",
            identity.deviceId,
            clientId,
            clientMode,
            role,
            scopeString,
            String(challenge.timestampMs),
            effectiveToken,
            challenge.nonce,
        ].joined(separator: "|")
        let signature = try identity.sign(signaturePayload)

        var auth: [String: Any] = ["token": effectiveToken]
        if let savedDeviceToken {
            auth["deviceToken"] = savedDeviceToken
        }

        let params: [String: Any] = [
            "minProtocol": 4,
            "maxProtocol": 4,
            "client": [
                "id": clientId,
                "displayName": "JARVIS",
                "version": "2.10.0",
                "platform": "ios",
                "deviceFamily": "iphone",
                "mode": clientMode,
            ],
            "role": role,
            "scopes": operatorScopes,
            "caps": ["tool-events"],
            "commands": [String](),
            "permissions": [String: Bool](),
            "auth": auth,
            "locale": Locale.preferredLanguages.first ?? "pt-BR",
            "userAgent": "JARVIS/2.10.0 (iOS)",
            "device": [
                "id": identity.deviceId,
                "publicKey": identity.publicKeyBase64URL,
                "signature": signature,
                "signedAt": challenge.timestampMs,
                "nonce": challenge.nonce,
            ],
        ]

        let response = try await sendRequest(method: .connect, params: params)
        guard response.ok else {
            let code = response.error?.code ?? "CONNECT_FAILED"
            let details = response.error?.details ?? [:]
            let requestId = details["requestId"]?.stringValue
                ?? details["pairingRequestId"]?.stringValue
            if code == "PAIRING_REQUIRED" || response.error?.message?.localizedCaseInsensitiveContains("pairing") == true {
                let suffix = requestId.map { " Request ID: \($0)." } ?? ""
                debugInfo = "Pairing required. Approve JARVIS on the OpenClaw PC.\(suffix)"
                throw AIBackendError.requestFailed("PAIRING_REQUIRED. Approve JARVIS on the PC with openclaw devices list / approve.\(suffix)")
            }
            throw AIBackendError.requestFailed(response.error?.message ?? code)
        }

        // hello-ok may mint a device token after pairing. Persist it per Gateway.
        if let payload = response.payload,
           let helloAuth = payload["auth"]?.dictionaryValue,
           let deviceToken = helloAuth["deviceToken"] as? String,
           !deviceToken.isEmpty {
            try? JARVISOpenClawDeviceAuthStore.saveDeviceToken(deviceToken, for: gatewayURL)
            print("[OpenClaw] Saved paired device token")
        }
    }

    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard connectionState.isUsable else { throw AIBackendError.notConnected }
        isProcessing = true
        accumulatedResponse = ""
        onProcessingChanged?(true)

        var params: [String: Any] = [
            "message": text,
            "sessionKey": Self.sessionKey,
            "idempotencyKey": UUID().uuidString,
        ]
        if let imageData {
            params["attachments"] = [[
                "type": "image",
                "mimeType": "image/jpeg",
                "content": imageData.base64EncodedString(),
            ]]
        }

        let response = try await sendRequest(method: .sendMessage, params: params)
        guard response.ok else {
            isProcessing = false
            onProcessingChanged?(false)
            throw AIBackendError.requestFailed(response.error?.message ?? "Message failed")
        }
    }

    func cancelRequest() {
        guard connectionState.isUsable else { return }
        Task { _ = try? await sendRequest(method: .cancelRun, params: [:]) }
        isProcessing = false
        isToolRunning = false
        currentToolName = nil
        onProcessingChanged?(false)
        onToolStatusChanged?(nil, false)
    }

    func interrupt() async {
        cancelRequest()
    }

    func sendToolResult(callId: String, result: String) async throws {
        guard connectionState.isUsable else { return }
        _ = try await sendRequest(method: .toolResult, params: ["callId": callId, "result": result])
    }

    private func sendRequest(method: OpenClawMethod, params: [String: Any]) async throws -> OpenClawResponse {
        guard let webSocket, webSocket.state == .running else { throw AIBackendError.notConnected }
        requestCounter += 1
        let requestId = "req-\(requestCounter)-\(UUID().uuidString.prefix(6))"
        let request = OpenClawRequest(id: requestId, method: method.rawValue, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            webSocket.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    if self?.pendingRequests.removeValue(forKey: requestId) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let webSocket = self.webSocket else { return }
                do {
                    let message = try await webSocket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.handleConnectionDrop(error: error)
                    }
                    return
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }

        if let response = try? JSONDecoder().decode(OpenClawResponse.self, from: data), response.type == "res" {
            if let continuation = pendingRequests.removeValue(forKey: response.id) {
                continuation.resume(returning: response)
            }
            return
        }

        if let event = try? JSONDecoder().decode(OpenClawEvent.self, from: data), event.type == "event" {
            if event.event == "connect.challenge",
               let payload = event.payload,
               let nonce = payload["nonce"]?.stringValue,
               !nonce.isEmpty {
                let timestamp: Int64?
                if let int = payload["ts"]?.intValue {
                    timestamp = Int64(int)
                } else if let double = payload["ts"]?.doubleValue {
                    timestamp = Int64(double)
                } else {
                    timestamp = nil
                }
                if let timestamp, timestamp >= 0 {
                    latestChallenge = ConnectChallenge(nonce: nonce, timestampMs: timestamp)
                    print("[OpenClaw] Received connect.challenge")
                }
                return
            }
            handleEvent(event)
            return
        }

        print("[OpenClaw] Unknown frame")
    }

    private func handleEvent(_ event: OpenClawEvent) {
        guard let payload = event.payload else { return }

        switch event.event {
        case "agent":
            let stream = payload["stream"]?.stringValue ?? ""
            let data = payload["data"]?.dictionaryValue ?? [:]
            if stream == "assistant", let text = data["text"] as? String, !text.isEmpty {
                accumulatedResponse += text
            } else if stream == "tool" {
                if let toolName = data["name"] as? String {
                    currentToolName = toolName
                    isToolRunning = true
                    onToolStatusChanged?(toolName, true)
                    let args = data["arguments"] as? [String: Any] ?? data["input"] as? [String: Any] ?? [:]
                    let callId = data["id"] as? String ?? data["callId"] as? String
                    onToolCall?(toolName, args) { [weak self] result in
                        Task { @MainActor in
                            if let callId { try? await self?.sendToolResult(callId: callId, result: result) }
                            self?.isToolRunning = false
                            self?.onToolStatusChanged?(toolName, false)
                        }
                    }
                }
                if data["status"] as? String == "complete" {
                    isToolRunning = false
                    onToolStatusChanged?(currentToolName, false)
                }
            }

        case "chat":
            let state = payload["state"]?.stringValue ?? ""
            switch state {
            case "delta":
                appendTextBlocks(from: payload)
            case "final":
                isProcessing = false
                onProcessingChanged?(false)
                let finalText = textBlocks(from: payload)
                let responseText = finalText.isEmpty ? accumulatedResponse : finalText
                accumulatedResponse = ""
                if !responseText.isEmpty { onAgentMessage?(responseText) }
            case "error":
                isProcessing = false
                onProcessingChanged?(false)
                let message = payload["errorMessage"]?.stringValue ?? "OpenClaw error"
                lastError = message
                accumulatedResponse = ""
                onAgentMessage?("OpenClaw error: \(message)")
            case "aborted":
                isProcessing = false
                onProcessingChanged?(false)
                accumulatedResponse = ""
            default:
                break
            }

        case "tick", "presence", "health", "connect.challenge":
            break
        default:
            break
        }
    }

    private func textBlocks(from payload: [String: AnyCodable]) -> String {
        guard let message = payload["message"]?.dictionaryValue,
              let content = message["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    private func appendTextBlocks(from payload: [String: AnyCodable]) {
        let text = textBlocks(from: payload)
        if !text.isEmpty { accumulatedResponse += text }
    }

    private func handleConnectionDrop(error: Error) async {
        print("[OpenClaw] Connection dropped: \(error.localizedDescription)")
        guard !intentionalDisconnect else {
            transition(to: .disconnected)
            return
        }
        if hasConnectedBefore && isNetworkAvailable {
            transition(to: .reconnecting(attempt: 1))
        } else {
            transition(to: .failed(error.localizedDescription))
        }
    }

    private func scheduleReconnect(attempt: Int) {
        guard attempt <= Constants.OpenClaw.maxReconnectAttempts else {
            transition(to: .failed("Max reconnect attempts exceeded"))
            return
        }
        let exponential = min(
            Constants.OpenClaw.maxReconnectDelay,
            Constants.OpenClaw.initialReconnectDelay * pow(2.0, Double(attempt - 1)))
        let delay = Double.random(in: 0...exponential)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect(attempt: attempt)
        }
    }

    private func attemptReconnect(attempt: Int) async {
        guard case .reconnecting = connectionState else { return }
        do {
            try await performConnect()
        } catch {
            if case .reconnecting = connectionState {
                transition(to: .reconnecting(attempt: attempt + 1))
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Constants.OpenClaw.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        awaitingPong = false
    }

    private func sendPing() async {
        guard let webSocket, webSocket.state == .running else { return }
        if awaitingPong {
            await handleConnectionDrop(error: AIBackendError.connectionTimeout)
            return
        }
        awaitingPong = true
        webSocket.sendPing { [weak self] error in
            Task { @MainActor in
                if let error {
                    await self?.handleConnectionDrop(error: error)
                } else {
                    self?.awaitingPong = false
                }
            }
        }
    }

    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        latestChallenge = nil
    }

    private func failPendingRequests(error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                if !wasAvailable && self.isNetworkAvailable && self.connectionState == .suspended {
                    try? await self.connect()
                } else if wasAvailable && !self.isNetworkAvailable && self.connectionState.isUsable {
                    self.transition(to: .suspended)
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func setupLifecycleObservers() {
        let background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleAppBackground() }
            }
        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleAppForeground() }
            }
        lifecycleObservers = [background, foreground]
    }

    private func handleAppBackground() {
        if connectionState.isUsable {
            wasConnectedBeforeSuspend = true
            transition(to: .suspended)
        } else {
            wasConnectedBeforeSuspend = false
        }
    }

    private func handleAppForeground() async {
        if wasConnectedBeforeSuspend && connectionState == .suspended {
            try? await connect()
        }
    }

    func testConnection() async -> Result<Void, Error> {
        guard gatewayURL != nil, !authToken.isEmpty else {
            return .failure(AIBackendError.notConfigured)
        }
        do {
            let wasConnected = connectionState.isUsable
            if !wasConnected { try await connect() }
            if !wasConnected { await disconnect() }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func isPairingOrAuthError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("pairing_required")
            || text.contains("pairing required")
            || text.contains("unauthorized")
            || text.contains("authentication")
            || text.contains("invalid token")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
