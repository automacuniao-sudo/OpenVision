// JARVIS - FaceRecognitionTool.swift
// Private on-device face memory exposed to function-calling backends.

import Foundation

struct FaceRecognitionTool: NativeTool {
    let name = "face_recognition"
    let description = """
    Recognize or remember a real person physically in view using JARVIS's private on-device face memory.     Use action 'identify' when the user asks who the person currently in front of the camera is;     'remember' when they explicitly ask to save that person's face under a provided name;     'forget' to delete a saved person; and 'list' to list known people.     Never use this to identify celebrities/public figures from general knowledge or the web.     The image is processed on-device and is not sent to the model. Camera source defaults to Ray-Ban glasses when connected, otherwise the iPhone rear camera.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["identify", "remember", "forget", "list"],
                "description": "Face-memory action to perform."
            ],
            "name": [
                "type": "string",
                "description": "Person's name. Required for remember/forget; empty for identify/list."
            ],
            "camera_source": [
                "type": "string",
                "enum": ["auto", "glasses", "phone"],
                "description": "Optional. Use phone only when the user explicitly asks for the iPhone/cellphone camera; otherwise auto."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "").lowercased()
        let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let source: VisionCaptureService.CaptureSource
        switch (args["camera_source"] as? String ?? "auto").lowercased() {
        case "phone", "iphone", "cellphone":
            source = .phone
        case "glasses", "rayban", "ray-ban":
            source = .glasses
        default:
            source = .automatic
        }

        switch action {
        case "list":
            return await MainActor.run {
                FaceRecognitionService.shared.listKnownFaces()
            }

        case "forget":
            guard !name.isEmpty else { return "Diga o nome da pessoa que devo esquecer." }
            return await MainActor.run {
                FaceRecognitionService.shared.forgetFace(name: name)
            }

        case "identify":
            let captured = try await VisionCaptureService.shared.captureImage(preferred: source)
            await MainActor.run {
                DiagnosticLogger.shared.log("Face", "Tool identify source=\(captured.source.rawValue)")
            }
            return await FaceRecognitionService.shared.identify(in: captured.image)

        case "remember":
            guard !name.isEmpty else { return "Qual é o nome da pessoa que devo lembrar?" }
            let captured = try await VisionCaptureService.shared.captureImage(preferred: source)
            await MainActor.run {
                DiagnosticLogger.shared.log("Face", "Tool remember nameProvided=yes source=\(captured.source.rawValue)")
            }
            return await FaceRecognitionService.shared.rememberFace(name: name, from: captured.image)

        default:
            return "Use identify, remember, forget ou list."
        }
    }
}
