import XCTest
import ImageIO
@testable import JARVIS

final class FaceDiagnosticSupportTests: XCTestCase {
    func testOrientationLabelsAreStable() {
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.up), "up")
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.right), "right")
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.left), "left")
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.down), "down")
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.upMirrored), "upMirrored")
        XCTAssertEqual(FaceDiagnosticSupport.orientationLabel(.rightMirrored), "rightMirrored")
    }

    func testBoundingBoxSummaryUsesFixedPrecision() {
        let box = CGRect(x: 0.12345, y: 0.23456, width: 0.34567, height: 0.45678)
        XCTAssertEqual(
            FaceDiagnosticSupport.boundingBoxSummary(box),
            "x=0.123 y=0.235 w=0.346 h=0.457"
        )
    }
}
