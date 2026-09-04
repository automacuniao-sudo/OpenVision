import Foundation
import CoreGraphics
import ImageIO

enum FaceDiagnosticSupport {
    static func orientationLabel(_ orientation: CGImagePropertyOrientation) -> String {
        switch orientation {
        case .up: return "up"
        case .upMirrored: return "upMirrored"
        case .down: return "down"
        case .downMirrored: return "downMirrored"
        case .left: return "left"
        case .leftMirrored: return "leftMirrored"
        case .right: return "right"
        case .rightMirrored: return "rightMirrored"
        @unknown default: return "unknown(\(orientation.rawValue))"
        }
    }

    static func boundingBoxSummary(_ box: CGRect) -> String {
        String(
            format: "x=%.3f y=%.3f w=%.3f h=%.3f",
            box.origin.x,
            box.origin.y,
            box.size.width,
            box.size.height
        )
    }
}
