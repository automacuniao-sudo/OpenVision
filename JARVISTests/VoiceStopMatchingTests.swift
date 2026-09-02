import XCTest

final class VoiceStopMatchingTests: XCTestCase {
    func testBareStops() {
        XCTAssertTrue(VoiceStopMatching.isBareStopCommand("stop"))
        XCTAssertTrue(VoiceStopMatching.isBareStopCommand("pare"))
        XCTAssertTrue(VoiceStopMatching.isBareStopCommand("silêncio"))
        XCTAssertTrue(VoiceStopMatching.isBareStopCommand("cala a boca"))
        XCTAssertTrue(VoiceStopMatching.isBareStopCommand("stop agora"))
    }

    func testDoesNotMatchSubstring() {
        XCTAssertFalse(VoiceStopMatching.isBareStopCommand("desktop"))
        XCTAssertFalse(VoiceStopMatching.isBareStopCommand("abra o desktop"))
        XCTAssertFalse(VoiceStopMatching.isBareStopCommand("estou no desktop"))
        XCTAssertFalse(VoiceStopMatching.isBareStopCommand("para que serve o bluetooth"))
    }

    func testVideoStopIsSeparate() {
        XCTAssertFalse(VoiceStopMatching.isBareStopCommand("stop video"))
        XCTAssertTrue(VoiceStopMatching.isLiveVideoStopCommand("stop video"))
        XCTAssertTrue(VoiceStopMatching.isLiveVideoStopCommand("pare o video"))
        XCTAssertTrue(VoiceStopMatching.isLiveVideoStopCommand("encerrar stream"))
        XCTAssertFalse(VoiceStopMatching.isLiveVideoStopCommand("descreva o video"))
    }
}
