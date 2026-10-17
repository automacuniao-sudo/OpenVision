import Foundation

/// Shared source and ownership decisions, independent of UIKit and the DAT SDK.
enum CameraPolicy {
    enum Source: String {
        case automatic = "auto", glasses, phone
        case phoneFront = "phone_front", phoneBack = "phone_back"
    }
    enum FrameRoute { case dedicatedLive, conversationalGemini, preview }

    static func source(for command: String) -> Source {
        let text = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        if ["camera frontal", "pela frontal", "use a frontal", "front camera", "selfie"].contains(where: text.contains) { return .phoneFront }
        if ["camera traseira", "pela traseira", "use a traseira", "rear camera", "back camera", "camera do celular", "camera do iphone", "camera do telefone", "phone camera"].contains(where: text.contains) { return .phoneBack }
        return .automatic
    }

    static func shouldStopStream(startedHere: Bool, keepStreaming: Bool, sameSession: Bool = true) -> Bool {
        startedHere && !keepStreaming && sameSession
    }

    static func frameRoute(dedicatedLive: Bool, conversationalGemini: Bool) -> FrameRoute {
        if dedicatedLive { return .dedicatedLive }
        return conversationalGemini ? .conversationalGemini : .preview
    }
}

/// A tool snapshot owns the current visual turn; live frames resume on turn end/reset.
struct CameraFrameGate {
    private(set) var allowsLiveFrames = true
    mutating func beginCapture() { allowsLiveFrames = false }
    mutating func finishTurn() { allowsLiveFrames = true }
}

/// Guards asynchronous camera work against cancellation and a replacement tool batch.
struct CameraOperationIdentity {
    private(set) var active: UUID?
    private var callIDs: Set<String> = []
    mutating func begin(callIDs: Set<String> = []) -> UUID {
        let id = UUID()
        active = id
        self.callIDs = callIDs
        return id
    }
    mutating func cancel() { active = nil; callIDs = [] }
    func isCancelled(by ids: Set<String>) -> Bool {
        active != nil && !callIDs.isDisjoint(with: ids)
    }
    func isCurrent(_ id: UUID) -> Bool { active == id }
}
