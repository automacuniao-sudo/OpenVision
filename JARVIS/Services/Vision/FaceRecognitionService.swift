// OpenVision - FaceRecognitionService.swift
// On-device face recognition using Apple's Vision framework — no cloud, no model download.
//
// Pipeline: detect faces (VNDetectFaceRectangles) → crop → make a feature print
// (VNGenerateImageFeaturePrint) → match against saved faces with Vision's own
// `computeDistance` (lower = more similar). Feature prints are stored locally as archived
// observations. Approximate, not biometric-grade, but private and lightweight.

import Foundation
import Vision
import UIKit
import ImageIO

@MainActor
final class FaceRecognitionService: ObservableObject {

    static let shared = FaceRecognitionService()

    @Published private(set) var knownFaces: [KnownFace] = []

    struct KnownFace: Codable, Identifiable {
        var id = UUID()
        var name: String
        let printData: Data
        var lastSeen: Date
    }

    private let maxMatchDistance: Float = 0.5
    private let storageURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = docs.appendingPathComponent("known_faces_v2.json")
        load()
    }

    func rememberFace(name: String, from image: UIImage) async -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return "Qual nome devo salvar para essa pessoa?" }

        logInputImage(image, action: "remember")
        let normalizationStart = DispatchTime.now().uptimeNanoseconds
        guard let cgImage = Self.normalizedCGImage(from: image) else { return "Não consegui obter uma imagem nítida — tente novamente." }
        DiagnosticLogger.shared.log("Face", "Normalized action=remember pixels=\(cgImage.width)x\(cgImage.height) orientation=up normalizeMs=\(Self.elapsedMs(since: normalizationStart))")

        let pipeline = await Self.facePrintData(in: cgImage)
        pipeline.logs.forEach { DiagnosticLogger.shared.log("Face", $0) }
        guard let printData = pipeline.prints.first else {
            return "Não vejo um rosto com clareza. Peça para a pessoa olhar para a câmera e tente novamente."
        }

        if let idx = knownFaces.firstIndex(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            knownFaces[idx] = KnownFace(id: knownFaces[idx].id, name: cleanName, printData: printData, lastSeen: Date())
        } else {
            knownFaces.append(KnownFace(name: cleanName, printData: printData, lastSeen: Date()))
        }
        save()
        return "Certo — vou lembrar de \(cleanName)."
    }

    func identify(in image: UIImage) async -> String {
        guard !knownFaces.isEmpty else {
            return "Ainda não conheço ninguém. Diga “lembre essa pessoa como...” para me ensinar um rosto."
        }

        logInputImage(image, action: "identify")
        let normalizationStart = DispatchTime.now().uptimeNanoseconds
        guard let cgImage = Self.normalizedCGImage(from: image) else { return "Não consegui obter uma imagem nítida — tente novamente." }
        DiagnosticLogger.shared.log("Face", "Normalized action=identify pixels=\(cgImage.width)x\(cgImage.height) orientation=up normalizeMs=\(Self.elapsedMs(since: normalizationStart))")

        let pipeline = await Self.facePrintData(in: cgImage)
        pipeline.logs.forEach { DiagnosticLogger.shared.log("Face", $0) }
        let prints = pipeline.prints
        guard !prints.isEmpty else { return "Não vejo nenhum rosto agora." }

        let known = knownFaces.map { (name: $0.name, data: $0.printData) }
        var names: [String] = []
        for query in prints {
            if let idx = Self.bestMatchIndex(query: query, known: known, maxDistance: maxMatchDistance) {
                knownFaces[idx].lastSeen = Date()
                names.append(knownFaces[idx].name)
            }
        }
        save()

        switch names.count {
        case 0: return "Vejo um rosto, mas ainda não reconheço essa pessoa."
        case 1: return "Essa pessoa é \(names[0])."
        default: return "Reconheci: \(names.joined(separator: ", "))."
        }
    }

    func forgetFace(name: String) -> String {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let before = knownFaces.count
        knownFaces.removeAll { $0.name.lowercased() == target }
        save()
        return knownFaces.count < before ? "Certo, esqueci \(name)." : "Não tenho ninguém salvo como \(name)."
    }

    func listKnownFaces() -> String {
        guard !knownFaces.isEmpty else { return "Ainda não conheço ninguém." }
        let names = knownFaces.map { $0.name }
        return names.count == 1 ? "Conheço \(names[0])." : "Conheço \(names.count) pessoas: \(names.joined(separator: ", "))."
    }

    private func logInputImage(_ image: UIImage, action: String) {
        let raw = image.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
        DiagnosticLogger.shared.log(
            "Face",
            "Input action=\(action) uiOrientation=\(Self.uiOrientationLabel(image.imageOrientation)) uiSize=\(Int(image.size.width))x\(Int(image.size.height)) scale=\(String(format: "%.2f", image.scale)) rawPixels=\(raw)"
        )
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up {
            return image.cgImage
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }

    private static func uiOrientationLabel(_ orientation: UIImage.Orientation) -> String {
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

    private struct FacePrintPipelineResult: Sendable {
        let prints: [Data]
        let logs: [String]
    }

    nonisolated private static func facePrintData(in cgImage: CGImage) async -> FacePrintPipelineResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try computeFacePrintData(cgImage))
                } catch {
                    continuation.resume(returning: FacePrintPipelineResult(prints: [], logs: ["Pipeline error=\(error.localizedDescription)"]))
                }
            }
        }
    }

    nonisolated private static func computeFacePrintData(_ cgImage: CGImage) throws -> FacePrintPipelineResult {
        let totalStart = DispatchTime.now().uptimeNanoseconds
        var logs: [String] = []

        let detectionStart = DispatchTime.now().uptimeNanoseconds
        let faceRequest = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest])
        let faces = faceRequest.results ?? []
        logs.append("Detection orientation=implicit-up pixels=\(cgImage.width)x\(cgImage.height) faces=\(faces.count) detectMs=\(elapsedMs(since: detectionStart))")

        if faces.isEmpty {
            for orientation in [CGImagePropertyOrientation.up, .right, .left, .down] {
                let probeStart = DispatchTime.now().uptimeNanoseconds
                let probe = VNDetectFaceRectanglesRequest()
                do {
                    try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([probe])
                    logs.append("OrientationProbe orientation=\(FaceDiagnosticSupport.orientationLabel(orientation)) faces=\(probe.results?.count ?? 0) detectMs=\(elapsedMs(since: probeStart))")
                } catch {
                    logs.append("OrientationProbe orientation=\(FaceDiagnosticSupport.orientationLabel(orientation)) error=\(error.localizedDescription)")
                }
            }
            logs.append("Pipeline featurePrints=0 totalMs=\(elapsedMs(since: totalStart))")
            return FacePrintPipelineResult(prints: [], logs: logs)
        }

        var results: [Data] = []
        for (index, face) in faces.prefix(5).enumerated() {
            logs.append("Face[\(index)] bbox=\(FaceDiagnosticSupport.boundingBoxSummary(face.boundingBox))")
            guard let cropped = cropFace(from: cgImage, boundingBox: face.boundingBox) else {
                logs.append("Face[\(index)] crop=failed")
                continue
            }
            logs.append("Face[\(index)] cropPixels=\(cropped.width)x\(cropped.height)")

            let featureStart = DispatchTime.now().uptimeNanoseconds
            let printRequest = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([printRequest])
            guard let observation = printRequest.results?.first else {
                logs.append("Face[\(index)] featurePrint=none featureMs=\(elapsedMs(since: featureStart))")
                continue
            }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true) {
                results.append(data)
                logs.append("Face[\(index)] featurePrint=ok featureMs=\(elapsedMs(since: featureStart))")
            } else {
                logs.append("Face[\(index)] featurePrint=archive-failed featureMs=\(elapsedMs(since: featureStart))")
            }
        }

        logs.append("Pipeline featurePrints=\(results.count) totalMs=\(elapsedMs(since: totalStart))")
        return FacePrintPipelineResult(prints: results, logs: logs)
    }

    nonisolated private static func cropFace(from cgImage: CGImage, boundingBox: CGRect) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let pad: CGFloat = 0.15
        var rect = CGRect(
            x: (boundingBox.origin.x - pad * boundingBox.width) * w,
            y: (1 - boundingBox.origin.y - boundingBox.height - pad * boundingBox.height) * h,
            width: boundingBox.width * (1 + 2 * pad) * w,
            height: boundingBox.height * (1 + 2 * pad) * h
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }
        return cgImage.cropping(to: rect)
    }

    nonisolated private static func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    nonisolated private static func bestMatchIndex(query queryData: Data,
                                                   known: [(name: String, data: Data)],
                                                   maxDistance: Float) -> Int? {
        guard let query = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: queryData) else {
            return nil
        }
        var best: Int?
        var bestDist = maxDistance
        for (i, k) in known.enumerated() {
            guard let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: k.data) else { continue }
            var dist: Float = 0
            guard (try? query.computeDistance(&dist, to: stored)) != nil else { continue }
            NSLog("[OV] face distance to %@: %.4f (threshold %.2f)", k.name, dist, maxDistance)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    private func save() {
        try? JSONEncoder().encode(knownFaces).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let faces = try? JSONDecoder().decode([KnownFace].self, from: data) else { return }
        knownFaces = faces
    }
}
