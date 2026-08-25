from pathlib import Path
import subprocess

service_path = Path("JARVIS/Services/OpenClaw/OpenClawService.swift")
protocol_path = Path("JARVIS/Services/OpenClaw/OpenClawProtocol.swift")
project_path = Path("project.yml")

service = service_path.read_text(encoding="utf-8")
protocol = protocol_path.read_text(encoding="utf-8")
project = project_path.read_text(encoding="utf-8")

old_state = '''    private var lifecycleObservers: [Any] = []
    private var wasConnectedBeforeSuspend = false
    private var accumulatedResponse = ""

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
'''
new_state = '''    private var lifecycleObservers: [Any] = []
    private var wasConnectedBeforeSuspend = false
    private var accumulatedResponse = ""
    /// Run id returned by chat.send. Used to abort exactly the in-flight OpenClaw turn.
    private var activeRunId: String?

    private static var sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
'''
assert old_state in service, "OpenClaw state anchor changed"
service = service.replace(old_state, new_state, 1)

old_send = '''    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
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
'''
new_send = '''    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard connectionState.isUsable else { throw AIBackendError.notConnected }

        // OpenClaw 2026.7.1 can throw EmbeddedAttemptSessionTakeoverError if a second user turn
        // mutates the same session while the first embedded prompt temporarily released its lock.
        // JARVIS replacement speech is interruption semantics, so abort the old turn through the
        // official chat.abort RPC and wait for its acknowledgement before starting the new one.
        if isProcessing {
            await abortCurrentTurn()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

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
            activeRunId = nil
            isProcessing = false
            onProcessingChanged?(false)
            throw AIBackendError.requestFailed(response.error?.message ?? "Message failed")
        }
        activeRunId = response.payload?["runId"]?.stringValue
    }

    func cancelRequest() {
        guard connectionState.isUsable else { return }
        Task { [weak self] in
            await self?.abortCurrentTurn()
        }
    }

    func interrupt() async {
        await abortCurrentTurn()
    }

    /// Abort the active chat turn using the protocol-v4 chat.abort method. The old client used
    /// `run/cancel` with no session id; OpenClaw 2026.7.1 does not use that as the UI stop path,
    /// so the old turn could continue and collide with the replacement message.
    private func abortCurrentTurn() async {
        guard connectionState.isUsable else { return }
        var params: [String: Any] = ["sessionKey": Self.sessionKey]
        if let activeRunId { params["runId"] = activeRunId }
        let response = try? await sendRequest(method: .cancelRun, params: params)
        if response?.ok == false {
            print("[OpenClaw] chat.abort was rejected: \\(response?.error?.message ?? "unknown error")")
        }
        activeRunId = nil
        isProcessing = false
        isToolRunning = false
        currentToolName = nil
        accumulatedResponse = ""
        onProcessingChanged?(false)
        onToolStatusChanged?(nil, false)
    }
'''
assert old_send in service, "OpenClaw send/cancel anchor changed"
service = service.replace(old_send, new_send, 1)

old_events = '''            case "final":
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
                onAgentMessage?("OpenClaw error: \\(message)")
            case "aborted":
                isProcessing = false
                onProcessingChanged?(false)
                accumulatedResponse = ""
'''
new_events = '''            case "final":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                let finalText = textBlocks(from: payload)
                let responseText = finalText.isEmpty ? accumulatedResponse : finalText
                accumulatedResponse = ""
                if !responseText.isEmpty { onAgentMessage?(responseText) }
            case "error":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                let message = payload["errorMessage"]?.stringValue ?? "OpenClaw error"
                accumulatedResponse = ""
                if message.localizedCaseInsensitiveContains("session file changed while embedded prompt lock was released") {
                    // Known OpenClaw 2026.7.1 session-fence race. Do not read a Windows file path
                    // aloud; rotate the JARVIS session so the very next command starts cleanly.
                    Self.sessionKey = "jarvis-\\(UUID().uuidString.prefix(8))"
                    let friendly = "Houve um conflito interno de sessão no OpenClaw. A sessão já foi reiniciada; repita o comando."
                    lastError = friendly
                    debugInfo = "Recovered from OpenClaw session takeover race"
                    onAgentMessage?(friendly)
                } else {
                    lastError = message
                    onAgentMessage?("OpenClaw error: \\(message)")
                }
            case "aborted":
                activeRunId = nil
                isProcessing = false
                onProcessingChanged?(false)
                accumulatedResponse = ""
'''
assert old_events in service, "OpenClaw event anchor changed"
service = service.replace(old_events, new_events, 1)

old_cancel = '    case cancelRun = "run/cancel"\n'
new_cancel = '    case cancelRun = "chat.abort"\n'
assert old_cancel in protocol, "OpenClaw cancel method anchor changed"
protocol = protocol.replace(old_cancel, new_cancel, 1)

assert 'CURRENT_PROJECT_VERSION: "29"' in project, "Build number is not 29"
project = project.replace('CURRENT_PROJECT_VERSION: "29"', 'CURRENT_PROJECT_VERSION: "30"', 1)

service_path.write_text(service, encoding="utf-8")
protocol_path.write_text(protocol, encoding="utf-8")
project_path.write_text(project, encoding="utf-8")

subprocess.run(["git", "diff", "--check"], check=True)
subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
subprocess.run(["git", "add", str(service_path), str(protocol_path), str(project_path)], check=True)
subprocess.run(["git", "commit", "-m", "Stabilize OpenClaw turn interruption and session recovery"], check=True)
subprocess.run(["git", "push", "origin", "HEAD:jarvis-dev"], check=True)
