// OpenVision - GeminiLiveService.swift
// WebSocket client for Google Gemini Live API with native audio

import Foundation
import AVFoundation

/// Gemini Live WebSocket Service
///
/// Connects to Gemini Live API for real-time voice + vision AI.
/// Handles bidirectional audio streaming and video frame transmission.
@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var isToolRunning: Bool = false
    @Published var currentToolName: String?
    @Published var lastError: String?

    // MARK: - Configuration

    private var apiKey: String {
        SettingsManager.shared.settings.geminiAPIKey
    }

    private var videoFPS: Int {
        SettingsManager.shared.settings.geminiVideoFPS
    }

    private var voiceName: String {
        let configured = SettingsManager.shared.settings.geminiVoiceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "Charon" : configured
    }

    // MARK: - Callbacks

    var onTextReceived: ((String) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onToolStatusChanged: ((String?, Bool) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSetupComplete: Bool = false

    // MARK: - Session Resumption / Recovery

    /// Latest resumable state handle supplied by Gemini Live. It is intentionally kept only in
    /// memory and never written to Diagnostics. A normal user-ended conversation clears it; an
    /// unexpected socket reset keeps it so the new WebSocket can resume the same session.
    private var sessionResumptionHandle: String?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAfterTurn = false
    private var intentionalDisconnect = false
    private let maxReconnectAttempts = 4

    // MARK: - Normal voice-mode playback

    /// In normal Gemini voice mode the ViewModel does not install an audio callback (that callback
    /// is only installed for Live Video mode). Keep a local playback path so native Gemini audio
    /// is still audible. When Live Video provides `onAudioReceived`, that external path wins.
    private let fallbackAudioPlayback = AudioPlaybackService()
    private var fallbackAudioReady = false
    private var pendingTurnComplete = false
    private var discardIncomingAudio = false
    private var ignoreNextTurnComplete = false

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval {
        1.0 / Double(videoFPS)
    }

    // MARK: - Latency Tracking

    private var lastUserSpeechEnd: Date?
    private var currentTurnSentAt: Date?
    private var firstPCMSeenForTurn = false
    private var lastPCMReceivedAt: Date?
    private var maxPCMGapMs: Double = 0

    // MARK: - Initialization

    private init() {
        // A Gemini server turn can finish before the last locally queued PCM buffer is audible.
        // Finalize the conversational turn only when that queue really drains.
        fallbackAudioPlayback.onPlaybackComplete = { [weak self] in
            guard let self, self.pendingTurnComplete else { return }
            DiagnosticLogger.shared.log("Gemini", "PCM drained; finalizing deferred turn")
            self.finishTurn()
        }
    }

    // MARK: - Connection

    /// Connect to Gemini Live API
    func connect() async throws {
        intentionalDisconnect = false

        guard !apiKey.isEmpty else {
            throw AIBackendError.notConfigured
        }

        guard !connectionState.isUsable else { return }
        guard !connectionState.isAttempting else { return }

        connectionState = .connecting
        onConnectionStateChanged?(connectionState)
        DiagnosticLogger.shared.log("Gemini", "Connecting model=\(Constants.GeminiLive.modelName) voice=\(voiceName) resume=\(sessionResumptionHandle != nil)")

        do {
            let url = buildWebSocketURL()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30

            urlSession = URLSession(configuration: config)
            webSocket = urlSession?.webSocketTask(with: url)
            webSocket?.resume()

            startReceiving()

            // Wait for connection
            var connected = false
            for _ in 0..<15 {
                if webSocket?.state == .running {
                    connected = true
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard connected else {
                throw AIBackendError.connectionTimeout
            }

            // Send setup message
            try await sendSetup()

            // Wait for setup complete
            for _ in 0..<50 {
                if isSetupComplete {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard isSetupComplete else {
                throw AIBackendError.connectionFailed
            }

            connectionState = .connected
            onConnectionStateChanged?(connectionState)
            print("[GeminiLive] Connected")
            DiagnosticLogger.shared.log("Gemini", "Connected and setup complete resume=\(sessionResumptionHandle != nil)")

        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            onConnectionStateChanged?(connectionState)
            DiagnosticLogger.shared.log("Gemini", "Connect failed: \(error.localizedDescription)")
            closeWebSocket()
            throw error
        }
    }

    /// Disconnect from Gemini Live
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        print("[GeminiLive] Disconnecting")
        DiagnosticLogger.shared.log("Gemini", "Disconnecting (intentional)")
        intentionalDisconnect = true
        reconnectAfterTurn = false
        reconnectTask?.cancel()
        reconnectTask = nil
        sessionResumptionHandle = nil
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()

        // Live Video installs this callback temporarily. Clear it when the session ends so a later
        // normal wake-word session cannot keep pointing at a playback engine that was torn down.
        onAudioReceived = nil

        onDisconnected?()
    }

    /// Build WebSocket URL
    private func buildWebSocketURL() -> URL {
        var components = URLComponents(string: Constants.GeminiLive.websocketEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]
        return components.url!
    }

    /// Close WebSocket
    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        if fallbackAudioReady {
            fallbackAudioPlayback.teardown()
            fallbackAudioReady = false
        }

        isSetupComplete = false
        isModelSpeaking = false
        isToolRunning = false
        currentToolName = nil
        pendingTurnComplete = false
        discardIncomingAudio = false
        ignoreNextTurnComplete = false
    }

    // MARK: - Setup

    /// Send setup message to configure the session
    private func sendSetup() async throws {
        var resumption: [String: Any] = [:]
        if let handle = sessionResumptionHandle {
            resumption["handle"] = handle
        }

        let setup: [String: Any] = [
            "setup": [
                "model": Constants.GeminiLive.modelName,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": voiceName
                            ]
                        ]
                    ],
                    "thinkingConfig": [
                        "thinkingLevel": "minimal"
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": buildSystemPrompt()]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "prefixPaddingMs": 40,
                        "silenceDurationMs": 500
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any],
                "sessionResumption": resumption,
                "tools": buildToolDeclarations()
            ]
        ]

        DiagnosticLogger.shared.log("Gemini", "Sending session setup: AUDIO voice=\(voiceName) + pt-BR JARVIS + native tools + sessionResumption")
        try await sendJSON(setup)
    }

    /// Build system prompt
    private func buildSystemPrompt() -> String {
        let instant = Date()
        let localTimeZone = TimeZone.current
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "pt_BR")
        localFormatter.timeZone = localTimeZone
        localFormatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy, HH:mm:ss"
        let localNow = localFormatter.string(from: instant)

        let localDateFormatter = DateFormatter()
        localDateFormatter.locale = Locale(identifier: "pt_BR")
        localDateFormatter.timeZone = localTimeZone
        localDateFormatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy"
        let localToday = localDateFormatter.string(from: instant)

        var prompt = """
        Your name is JARVIS. You are the user's personal AI assistant for Project JARVIS, integrated with their iPhone and smart glasses. Do not present yourself as Gemini or as a generic virtual assistant. If the user asks who or what JARVIS is, explain naturally that J.A.R.V.I.S. from Iron Man is the fictional inspiration for the name and concept, while you are this user's real personal-assistant project — you are not the fictional Stark system.

        You can see what the user sees when a glasses/camera stream is actually available. Never pretend you can currently see something if no image or video frame was provided.

        Keep responses concise, natural, and conversational. The user is using JARVIS hands-free and expects quick answers.

        RESPOND IN BRAZILIAN PORTUGUESE (pt-BR). YOU MUST RESPOND UNMISTAKABLY IN BRAZILIAN PORTUGUESE unless the user explicitly asks for another language.

        DATE/TIME GROUND TRUTH FROM THE IPHONE: right now locally it is \(localNow), time zone \(localTimeZone.identifier). The local civil date called "hoje" is exactly \(localToday). Treat this iPhone-local date as authoritative. DO NOT convert it to UTC and accidentally call the next UTC date "today". For questions such as "que dia é hoje?", "hoje é dia quanto?" or "que horas são?", answer from this local clock. If the user explicitly asks to search the web, you may call web_search, but reconcile any result to this same iPhone-local calendar date.

        IMPORTANT: when the user asks JARVIS to perform an iPhone action that has a matching tool, CALL THE TOOL instead of merely explaining how to do it.

        INTERNET / CURRENT INFORMATION: the native tool `web_search` is available. CALL `web_search` whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current or time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not answer current facts from stale model memory when `web_search` can verify them. For example, "qual é o próximo jogo do Corinthians?" must call `web_search` before answering.

        Available on-device actions include:
        - device_status: read the real iPhone battery percentage, charging state, Low Power Mode, and iOS version. Use it for questions like "quanto de bateria eu tenho?".
        - calendar: manage the real Apple Calendar. Use action today/upcoming/add/update/delete for requests involving agenda, calendário, compromissos, reuniões or eventos.
        - create_reminder: manage the real Apple Reminders app. It supports create/list/update/delete. Use it whenever the user asks about lembretes.
        - set_timer and start_pomodoro: local timed notifications.
        - note: JARVIS INTERNAL notes only (save/search/list). This is NOT Apple Notes. Never claim that `note` created or edited a note in Apple's Notes app. Apple Notes integration is not available in this build yet.
        - copy_to_clipboard and search_docs as appropriate.
        - web_search: search the current internet for time-sensitive/current information.

        PERSONAL/PROJECT KNOWLEDGE: if the user asks for details about Project JARVIS, its goals,
        architecture, or personal facts about the user that are not already present in memories,
        call search_docs before saying you do not know. The user may have imported documents such
        as "JARVIS - Identidade e Objetivo" and "Perfil do Usuário". Never invent missing personal
        facts; if the imported profile does not contain the answer, say so briefly.

        For calendar/reminder clock times (for example "18 horas", "9:30", "amanhã às 14"), pass hour in 24-hour form, minute, and day_offset. For relative requests such as "daqui a 15 minutos", use minutes_from_now. Let the native tool do date arithmetic. After a tool runs, briefly confirm the actual result; never claim success if the tool returned an error or permission problem.

        If the user asks you to do something beyond the currently available tools, clearly say what is not yet integrated instead of pretending it was done.
        """

        // Add user's custom instructions
        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        // Add memories
        let memories = SettingsManager.shared.settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }

        return prompt
    }

    /// Build tool declarations for the Live voice session. Keep the session itself on custom
    /// function calling only: Gemini 3 Google Search grounding is paid-tier-only, so advertising
    /// googleSearch here breaks setup for the project's free-tier API key. Current-information
    /// requests are handled by the native `web_search` bridge instead.
    private func buildToolDeclarations() -> [[String: Any]] {
        [["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]]
    }

    // MARK: - Send Audio

    /// Send audio data to Gemini
    func sendAudio(data: Data) {
        // Full duplex: server VAD needs microphone PCM even while the model is speaking so the
        // user can interrupt naturally. `interrupted` already clears queued local playback.
        guard connectionState.isUsable else { return }

        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(Constants.GeminiLive.inputSampleRate)",
                    "data": data.base64EncodedString()
                ]
            ]
        ]

        Task {
            try? await sendJSON(message)
        }
    }

    /// Notify that user stopped speaking
    func userStoppedSpeaking() {
        lastUserSpeechEnd = Date()
    }

    /// Send text message to Gemini 3.1 Live.
    /// Gemini 3.1 only supports clientContent for seeding initial history;
    /// conversational text turns must use realtimeInput.text.
    func sendText(_ text: String) async throws {
        if !connectionState.isUsable {
            try await reconnectImmediately(reason: "text turn while disconnected")
        }

        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        // If this text is a barge-in follow-up, resume accepting model audio now. With automatic
        // activity detection enabled, realtimeInput.text itself counts as user activity and the
        // server's START_OF_ACTIVITY_INTERRUPTS policy cuts off the previous model response.
        discardIncomingAudio = false

        let message: [String: Any] = [
            "realtimeInput": [
                "text": text
            ]
        ]

        currentTurnSentAt = Date()
        firstPCMSeenForTurn = false
        lastPCMReceivedAt = nil
        maxPCMGapMs = 0

        DiagnosticLogger.shared.log("Gemini", "Sending text turn: \(text)")
        do {
            try await sendJSON(message)
        } catch {
            DiagnosticLogger.shared.log("Gemini", "Text send failed; reconnecting once: \(error.localizedDescription)")
            try await reconnectImmediately(reason: "text send failure")
            try await sendJSON(message)
            DiagnosticLogger.shared.log("Gemini", "Text turn resent after reconnect")
        }
    }

    /// Interrupt local playback immediately for barge-in. The next realtimeInput.text
    /// is user activity and asks Gemini's START_OF_ACTIVITY_INTERRUPTS policy to cut the server turn.
    /// Until that next user turn is sent, discard late PCM chunks from the response we just silenced.
    func interrupt() async {
        guard isModelSpeaking || isProcessing || fallbackAudioPlayback.isPlaying else { return }

        pendingTurnComplete = false
        ignoreNextTurnComplete = true
        discardIncomingAudio = true
        isModelSpeaking = false
        isProcessing = false
        fallbackAudioPlayback.stop()
        DiagnosticLogger.shared.log("Gemini", "Local barge-in: playback stopped; old PCM suppressed")
        print("[GeminiLive] Interrupted")
    }

    /// Rebuild the underlying Live WebSocket while preserving the latest session-resumption
    /// handle. Used by the conversation watchdog when the transport is alive-looking but silent.
    func recoverLiveSession(reason: String) async throws {
        guard !intentionalDisconnect else { throw AIBackendError.notConnected }
        DiagnosticLogger.shared.log("Gemini", "Conversation watchdog recovery requested: \(reason)")
        try await reconnectImmediately(reason: reason)
    }

    // MARK: - Send Video

    /// Send video frame to Gemini (throttled)
    func sendVideoFrame(imageData: Data) {
        guard connectionState.isUsable else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        let message: [String: Any] = [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": imageData.base64EncodedString()
                ]
            ]
        ]

        Task {
            try? await sendJSON(message)
        }
    }

    // MARK: - Send JSON

    /// Send JSON message
    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket = webSocket else {
            throw AIBackendError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: object)
        try await webSocket.send(.data(data))
    }

    // MARK: - Receive Loop

    /// Start receiving messages
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let webSocket = self.webSocket else { break }

                do {
                    let message = try await webSocket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        print("[GeminiLive] Receive error: \(error)")
                        DiagnosticLogger.shared.log("Gemini", "Receive error: \(error.localizedDescription)")
                        await self.handleDisconnect(reason: "receive error: \(error.localizedDescription)")
                    }
                    break
                }
            }
        }
    }

    /// Handle incoming message
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard let data = extractData(from: message),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Session resumption updates are sent only when sessionResumption was configured in
        // setup. Keep the newest resumable handle so a replacement WebSocket can preserve context.
        if let update = json["sessionResumptionUpdate"] as? [String: Any] {
            let resumable = update["resumable"] as? Bool ?? false
            if resumable, let handle = update["newHandle"] as? String, !handle.isEmpty {
                sessionResumptionHandle = handle
                DiagnosticLogger.shared.log("Gemini", "Session resumption handle updated (resumable=true)")
            } else if !resumable {
                DiagnosticLogger.shared.log("Gemini", "Session resumption update resumable=false")
            }
        }

        // Setup complete
        if json["setupComplete"] != nil {
            isSetupComplete = true
            DiagnosticLogger.shared.log("Gemini", "Received setupComplete")
            return
        }

        // API errors can arrive as a root-level WebSocket event during setup. Older builds ignored
        // these and later displayed only a generic backend failure, hiding the actual cause.
        if let apiError = json["error"] as? [String: Any] {
            let message = (apiError["message"] as? String) ?? "Unknown Gemini API error"
            lastError = message
            DiagnosticLogger.shared.log("Gemini", "Server API error: \(message)")
            print("[GeminiLive] Server API error: \(message)")
            return
        }

        // Server content (audio, text, etc.)
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
            return
        }

        // Input transcription (user's speech) - can come at root level
        if let inputTranscription = json["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            print("[GeminiLive] User said: \(text)")
            onInputTranscription?(text)
            return
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any] {
            await handleToolCall(toolCall)
            return
        }

        // GoAway is an advance warning that Gemini will close this WebSocket. If a response
        // is currently generating, let it finish and reconnect immediately after the turn; otherwise
        // replace the socket now using the latest resumable handle.
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = String(describing: goAway["timeLeft"] ?? "unknown")
            DiagnosticLogger.shared.log("Gemini", "GoAway received timeLeft=\(timeLeft)")
            if isProcessing || isModelSpeaking {
                reconnectAfterTurn = true
                DiagnosticLogger.shared.log("Gemini", "GoAway recovery deferred until turn complete")
            } else {
                scheduleReconnect(reason: "GoAway timeLeft=\(timeLeft)")
            }
            return
        }
    }

    /// Extract data from WebSocket message
    private func extractData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return nil
        }
    }

    /// Handle server content. Process ALL sibling fields before honoring turnComplete because
    /// Gemini 3.1 can deliver modelTurn/transcription and turnComplete in the same server event.
    private func handleServerContent(_ content: [String: Any]) {
        // Interrupted content should stop queued audio immediately.
        if content["interrupted"] as? Bool == true {
            pendingTurnComplete = false
            ignoreNextTurnComplete = false
            isModelSpeaking = false
            isProcessing = false
            fallbackAudioPlayback.stop()
            DiagnosticLogger.shared.log("Gemini", "Server content interrupted")
            onInterrupted?()
        }

        // Model turn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {

                    // Track latency for first audio
                    if !isModelSpeaking, let speechEnd = lastUserSpeechEnd {
                        let latency = Date().timeIntervalSince(speechEnd) * 1000
                        print("[GeminiLive] Latency: \(Int(latency))ms")
                        lastUserSpeechEnd = nil
                    }

                    // After a local barge-in, late chunks from the old response can still
                    // arrive until the next user realtimeInput reaches Gemini. Never let them restart
                    // audio the user explicitly stopped.
                    if discardIncomingAudio {
                        DiagnosticLogger.shared.log("GeminiAudio", "Discarded old PCM chunk bytes=\(audioData.count)")
                        continue
                    }

                    let pcmNow = Date()
                    if !firstPCMSeenForTurn, let sentAt = currentTurnSentAt {
                        firstPCMSeenForTurn = true
                        let firstMs = Int(pcmNow.timeIntervalSince(sentAt) * 1000)
                        DiagnosticLogger.shared.log("Latency", "Gemini send→firstPCM=\(firstMs)ms")
                    }
                    if let previousPCM = lastPCMReceivedAt {
                        let gapMs = pcmNow.timeIntervalSince(previousPCM) * 1000
                        maxPCMGapMs = max(maxPCMGapMs, gapMs)
                        if gapMs >= 500 {
                            DiagnosticLogger.shared.log("Latency", "Gemini PCM gap=\(Int(gapMs))ms")
                        }
                    }
                    lastPCMReceivedAt = pcmNow

                    isModelSpeaking = true
                    isProcessing = true
                    DiagnosticLogger.shared.log("GeminiAudio", "Received PCM chunk bytes=\(audioData.count)")

                    if let onAudioReceived {
                        // Live Video mode owns playback through the ViewModel.
                        onAudioReceived(audioData)
                    } else {
                        // Normal wake-word Gemini mode has no ViewModel audio callback. Without this
                        // fallback the model returns valid PCM audio but the app silently discards it.
                        if !fallbackAudioReady {
                            do {
                                try fallbackAudioPlayback.setup()
                                fallbackAudioReady = true
                                print("[GeminiLive] Normal voice playback ready")
                                DiagnosticLogger.shared.log("GeminiAudio", "Normal voice playback ready")
                            } catch {
                                lastError = "Audio playback setup failed: \(error.localizedDescription)"
                                print("[GeminiLive] \(lastError ?? "Audio playback setup failed")")
                                DiagnosticLogger.shared.log("GeminiAudio", lastError ?? "Audio playback setup failed")
                            }
                        }
                        if fallbackAudioReady {
                            fallbackAudioPlayback.playAudio(data: audioData)
                        }
                    }
                }

                // Text (some model events put transcript text directly in a part).
                if let text = part["text"] as? String, !text.isEmpty {
                    onOutputTranscription?(text)
                }
            }
        }

        // Output transcription can be delivered alongside modelTurn as a sibling field.
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String, !text.isEmpty {
            DiagnosticLogger.shared.log("Gemini", "Output transcript: \(text)")
            onOutputTranscription?(text)
        }

        // Input transcription
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            onInputTranscription?(text)
        }

        // Turn complete comes LAST so we never discard sibling audio/transcription fields.
        if content["turnComplete"] as? Bool == true {
            // A locally interrupted response may still report its final boundary. Consume that
            // boundary without reopening conversation mode in the middle of the user's barge-in.
            if ignoreNextTurnComplete {
                ignoreNextTurnComplete = false
                pendingTurnComplete = false
                isModelSpeaking = false
                isProcessing = false
                DiagnosticLogger.shared.log("Gemini", "Ignored turnComplete for interrupted response")
                return
            }

            isProcessing = false
            if onAudioReceived == nil && fallbackAudioReady && fallbackAudioPlayback.isPlaying {
                // Normal wake-word mode: server generation is done, but local PCM is still audible.
                // Defer the conversation timeout/listening state until the actual speaker queue drains.
                pendingTurnComplete = true
                DiagnosticLogger.shared.log("Gemini", "Server turn complete; waiting for PCM drain")
            } else {
                finishTurn()
            }
        }
    }

    private func finishTurn() {
        pendingTurnComplete = false
        isModelSpeaking = false
        isProcessing = false

        if let sentAt = currentTurnSentAt {
            let totalMs = Int(Date().timeIntervalSince(sentAt) * 1000)
            DiagnosticLogger.shared.log("Latency", "Gemini send→turnComplete=\(totalMs)ms maxPCMGap=\(Int(maxPCMGapMs))ms")
        }
        currentTurnSentAt = nil
        firstPCMSeenForTurn = false
        lastPCMReceivedAt = nil
        maxPCMGapMs = 0

        DiagnosticLogger.shared.log("Gemini", "Turn complete")
        onTurnComplete?()

        if reconnectAfterTurn {
            reconnectAfterTurn = false
            scheduleReconnect(reason: "deferred GoAway after turn")
        }
    }

    /// Handle a tool call from Gemini: run each requested native tool and send the results back as a
    /// `toolResponse` so the model can speak a grounded confirmation in the same turn.
    private func handleToolCall(_ toolCall: [String: Any]) async {
        guard let calls = toolCall["functionCalls"] as? [[String: Any]], !calls.isEmpty else {
            print("[GeminiLive] toolCall with no functionCalls: \(toolCall)")
            return
        }

        // Function calling in Gemini Live is synchronous: keep the realtime session open and
        // mark the turn as busy until every tool result has been sent back to the same socket.
        isProcessing = true
        var responses: [[String: Any]] = []
        for call in calls {
            guard let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            currentToolName = name
            isToolRunning = true
            onToolStatusChanged?(name, true)
            DiagnosticLogger.shared.log("Gemini", "Tool running in persistent session: \(name)")

            let result = await NativeToolRegistry.shared.execute(name: name, args: args)

            isToolRunning = false
            currentToolName = nil
            onToolStatusChanged?(name, false)
            var response: [String: Any] = ["name": name, "response": ["result": result]]
            if let id = call["id"] as? String { response["id"] = id }  // echo id so Gemini pairs the response
            responses.append(response)
        }

        guard !responses.isEmpty else { return }
        do {
            try await sendJSON(["toolResponse": ["functionResponses": responses]])
        } catch {
            print("[GeminiLive] Failed to send toolResponse: \(error)")
            DiagnosticLogger.shared.log("Tool", "Failed to send toolResponse: \(error.localizedDescription)")
        }
    }

    /// Replace a dead socket synchronously when the current user turn needs to be sent now.
    /// The latest session-resumption handle is preserved.
    private func reconnectImmediately(reason: String) async throws {
        guard !intentionalDisconnect else { throw AIBackendError.notConnected }
        DiagnosticLogger.shared.log("Gemini", "Immediate reconnect: \(reason) resume=\(sessionResumptionHandle != nil)")
        closeWebSocket()
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        try await connect()
    }

    /// Schedule bounded reconnect attempts for receive failures and GoAway. The service keeps the
    /// conversation alive instead of notifying the ViewModel that the backend is permanently gone
    /// after the first transport hiccup.
    private func scheduleReconnect(reason: String) {
        guard !intentionalDisconnect else { return }
        guard reconnectTask == nil else { return }

        DiagnosticLogger.shared.log("Gemini", "Scheduling reconnect: \(reason) resume=\(sessionResumptionHandle != nil)")
        closeWebSocket()
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var lastReconnectError: Error?

            for attempt in 1...self.maxReconnectAttempts {
                if Task.isCancelled || self.intentionalDisconnect {
                    self.reconnectTask = nil
                    return
                }

                if attempt > 1 {
                    let delay = min(pow(2.0, Double(attempt - 2)), 4.0)
                    DiagnosticLogger.shared.log("Gemini", "Reconnect backoff=\(String(format: "%.1f", delay))s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                guard !Task.isCancelled, !self.intentionalDisconnect else {
                    self.reconnectTask = nil
                    return
                }

                DiagnosticLogger.shared.log("Gemini", "Reconnect attempt \(attempt)/\(self.maxReconnectAttempts)")
                self.closeWebSocket()
                self.connectionState = .disconnected
                self.onConnectionStateChanged?(self.connectionState)

                do {
                    try await self.connect()
                    DiagnosticLogger.shared.log("Gemini", "Reconnect succeeded attempt=\(attempt) resume=\(self.sessionResumptionHandle != nil)")
                    self.reconnectTask = nil
                    return
                } catch {
                    lastReconnectError = error
                    DiagnosticLogger.shared.log("Gemini", "Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }

            self.reconnectTask = nil
            let message = lastReconnectError?.localizedDescription ?? "reconnect failed"
            self.lastError = message
            self.connectionState = .failed(message)
            self.onConnectionStateChanged?(self.connectionState)
            DiagnosticLogger.shared.log("Gemini", "Reconnect exhausted: \(message)")
            self.onDisconnected?()
        }
    }

    /// Handle an unexpected receive-side disconnect.
    private func handleDisconnect(reason: String) async {
        if intentionalDisconnect {
            connectionState = .disconnected
            onConnectionStateChanged?(connectionState)
            closeWebSocket()
            onDisconnected?()
            return
        }
        scheduleReconnect(reason: reason)
    }
}
