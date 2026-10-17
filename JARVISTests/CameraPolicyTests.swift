import XCTest
#if !JARVIS_PURE_TESTS
@testable import JARVIS
#endif

final class CameraPolicyTests: XCTestCase {
    func testDefaultsAndSelfRequestsPreferGlasses() {
        for text in ["o que estou vendo", "me reconheça", "olhe para mim", "ative reconhecimento facial", "use os óculos"] {
            XCTAssertEqual(CameraPolicy.source(for: text), .automatic)
        }
    }
    func testExplicitPhoneOverridesGlasses() {
        XCTAssertEqual(CameraPolicy.source(for: "use a câmera do celular"), .phoneBack)
        XCTAssertEqual(CameraPolicy.source(for: "olhe pela câmera frontal"), .phoneFront)
        XCTAssertEqual(CameraPolicy.source(for: "use a câmera traseira do iPhone"), .phoneBack)
    }
    func testBorrowedStreamIsNeverStoppedByCapture() {
        XCTAssertFalse(CameraPolicy.shouldStopStream(startedHere: false, keepStreaming: false))
        XCTAssertTrue(CameraPolicy.shouldStopStream(startedHere: true, keepStreaming: false))
        XCTAssertFalse(CameraPolicy.shouldStopStream(startedHere: true, keepStreaming: true))
    }
    func testCaptureCannotStopReplacementSession() {
        XCTAssertFalse(CameraPolicy.shouldStopStream(startedHere: true, keepStreaming: false, sameSession: false))
        XCTAssertTrue(CameraPolicy.shouldStopStream(startedHere: true, keepStreaming: false, sameSession: true))
    }
    func testDedicatedRouteWinsAndConversationRouteReturns() {
        XCTAssertEqual(CameraPolicy.frameRoute(dedicatedLive: true, conversationalGemini: true), .dedicatedLive)
        XCTAssertEqual(CameraPolicy.frameRoute(dedicatedLive: false, conversationalGemini: true), .conversationalGemini)
        XCTAssertEqual(CameraPolicy.frameRoute(dedicatedLive: false, conversationalGemini: false), .preview)
    }
    func testCancelledOperationCannotMutateReplacementToolState() {
        var operation = CameraOperationIdentity()
        let old = operation.begin()
        operation.cancel()
        let replacement = operation.begin()
        XCTAssertFalse(operation.isCurrent(old))
        XCTAssertTrue(operation.isCurrent(replacement))
        operation.cancel()
        XCTAssertFalse(operation.isCurrent(replacement))
    }
    func testDelayedCancellationDoesNotCancelReplacementBatch() {
        var operation = CameraOperationIdentity()
        _ = operation.begin(callIDs: ["old-call"])
        _ = operation.begin(callIDs: ["current-call", "second-current-call"])
        XCTAssertFalse(operation.isCancelled(by: ["old-call"]))
        XCTAssertFalse(operation.isCancelled(by: []))
        XCTAssertTrue(operation.isCancelled(by: ["second-current-call"]))
        operation.cancel()
        XCTAssertFalse(operation.isCancelled(by: ["current-call"]))
    }
    func testPhoneSnapshotSuppressionEndsWithTurnOrReset() {
        var policy = CameraFrameGate()
        XCTAssertTrue(policy.allowsLiveFrames)
        policy.beginCapture()
        XCTAssertFalse(policy.allowsLiveFrames)
        policy.finishTurn()
        XCTAssertTrue(policy.allowsLiveFrames)
        policy.beginCapture()
        policy.finishTurn()
        XCTAssertTrue(policy.allowsLiveFrames)
    }
}
