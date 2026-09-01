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

@MainActor
final class FaceRecognitionService: ObservableObject {

    static let shared = FaceRecognitionService()

    @Published private(set) var knownFaces: [KnownFace] = []

    struct KnownFace: Codable, Identifiable {
        var id = UUID()
        var name: String
        let printData: Data   // archived VNFeaturePrintObservation
        var lastSeen: Date
    }

    /// Max feature-print distance to count as a match (lower distance = more similar).
    /// Tuned from real device data: correct matches measured ≤ 0.48, wrong faces / non-faces
    /// ≥ 0.53, so 0.50 cleanly separates them and rejects the "no face → names someone" case.
    private let maxMatchDistance: Float = 0.5

    private let storageURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = docs.appendingPathComponent("known_faces_v2.json")
        load()
    }

    // MARK: - Enroll / manage

    func rememberFace(name: String, from image: UIImage) async -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return "Qual nome devo salvar para essa pessoa?" }
        guard let cgImage = Self.normalizedCGImage(from: image) else { return "Não consegui obter uma imagem nítida — tente novamente." }

        let prints = await Self.facePrintData(in: cgImage)
        guard let printData = prints.first else {
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
        guard let cgImage = Self.normalizedCGImage(from: image) else { return "Não consegui obter uma imagem nítida — tente novamente." }

        let prints = await Self.facePrintData(in: cgImage)
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

    /// Phone-camera JPEGs commonly arrive with orientation metadata instead of physically rotated
    /// pixels. Vision receives the CGImage pixels, so render an upright copy before face detection.
    /// Glasses frames that are already .up pass through without an extra allocation.
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

    // MARK: - Vision (off the main thread; returns Sendable Data)

    /// Detect faces and return each face's feature print, archived as Data.
    nonisolated private static func facePrintData(in cgImage: CGImage) async -> [Data] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? computeFacePrintData(cgImage)) ?? [])
            }
        }
    }

    nonisolated private static func computeFacePrintData(_ cgImage: CGImage) throws -> [Data] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest])
        guard let faces = faceRequest.results, !faces.isEmpty else { return [] }

        var results: [Data] = []
        for face in faces.prefix(5) {
            guard let cropped = cropFace(from: cgImage, boundingBox: face.boundingBox) else { continue }
            let printRequest = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([printRequest])
            guard let observation = printRequest.results?.first else { continue }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true) {
                results.append(data)
            }
        }
        return results
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

    // MARK: - Matching (Vision's computeDistance; lower = more similar)

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

    // MARK: - Persistence

    private func save() {
        try? JSONEncoder().encode(knownFaces).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let faces = try? JSONDecoder().decode([KnownFace].self, from: data) else { return }
        knownFaces = faces
    }
}
