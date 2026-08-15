import Foundation
import AppKit
import Vision

extension CGRect {
    fileprivate var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension CGPoint {
    fileprivate func distance(to other: CGPoint) -> CGFloat {
        sqrt(pow(x - other.x, 2) + pow(y - other.y, 2))
    }
}

/// On-device photo intelligence: detects faces in images, computes a 2048-dim
/// identity signature per face (VNGenerateImageFeaturePrintRequest over the
/// tight face crop — the macOS 26 SDK removed the legacy face-identity API),
/// clusters them into people and persists everything locally. Faces never sync
/// — they are derived, private data that belongs to this device only.
actor FaceEngine {
    static let shared = FaceEngine()

    /// Min cosine similarity for a face to join an existing person's centroid.
    private let matchThreshold: Double = 0.55
    /// Min centroid similarity for two people to be merged into one.
    private let mergeThreshold: Double = 0.80
    /// Faces smaller than this (pixels) are ignored as noise.
    private let minFacePixels: CGFloat = 48

    /// Indexes an image if it hasn't been indexed yet (idempotent per object).
    func indexIfNeeded(fileURL: URL, objectID: String) async {
        let counts = (try? await DatabaseManager.shared.faceCountsByObject()) ?? [:]
        guard counts[objectID] == nil else { return }
        await index(fileURL: fileURL, objectID: objectID)
    }

    /// Full pipeline for one image: detect → filter → embed → crop thumbs →
    /// cluster → persist. Never throws — best-effort background intelligence.
    ///
    /// Embeddings: the macOS 26 SDK removed the legacy face-identity API
    /// (VNCreateFaceprintRequest), so each face's signature is the 2048-dim
    /// VNGenerateImageFeaturePrintRequest featureprint computed on the tight
    /// face crop — the crop's visual appearance (shape, skin, hair, glasses)
    /// is a strong identity signal for clustering a personal library.
    func index(fileURL: URL, objectID: String) async {
        guard let image = NSImage(contentsOf: fileURL),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faceReq = VNDetectFaceRectanglesRequest()
        let qualityReq = VNDetectFaceCaptureQualityRequest()
        try? handler.perform([faceReq, qualityReq])

        let detected = faceReq.results ?? []
        guard !detected.isEmpty else { return }
        // Pair each detection with the capture-quality observation whose center
        // is closest (the two request runs can return separate instances).
        let qualityObs = qualityReq.results ?? []
        let faces = detected.compactMap { obs -> (VNFaceObservation, Double)? in
            let box = obs.boundingBox
            guard box.width * w >= minFacePixels, box.height * h >= minFacePixels else { return nil }
            let quality = qualityObs
                .min { $0.boundingBox.center.distance(to: box.center) < $1.boundingBox.center.distance(to: box.center) }
                .flatMap(\.faceCaptureQuality) ?? 0.5
            guard quality >= 0.15 else { return nil }
            return (obs, Double(quality))
        }
        guard !faces.isEmpty else { return }

        for (obs, quality) in faces {
            let box = obs.boundingBox
            let rect = Self.facePixelRect(cg: cg, box: box)
            guard let crop = cg.cropping(to: rect) else { continue }
            guard let vec = Self.embedding(of: crop), vec.reduce(0, { $0 + $1 * $1 }) > 0 else { continue }

            let faceID = UUID().uuidString
            let personID = await bestPerson(for: vec)
            saveFaceThumb(cg: cg, box: box, objectID: objectID, faceID: faceID)

            let face = FaceRecord(
                id: faceID,
                objectID: objectID,
                personID: personID,
                boxX: Double(box.midX),
                boxY: Double(box.midY),
                boxW: Double(box.width),
                boxH: Double(box.height),
                quality: quality,
                vectorData: Self.data(from: vec),
                createdAt: Date()
            )
            try? await DatabaseManager.shared.saveFace(face)
        }
        // Growing clusters over time: merge people whose centroids drifted together.
        await mergePass()
        await notifyChanged()
    }

    /// 2048-dim visual featureprint of a face crop — the identity signature.
    static func embedding(of crop: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do {
            try handler.perform([req])
            guard let obs = req.results?.first else { return nil }
            return floats(from: obs.data)
        } catch {
            return nil
        }
    }

    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    /// Padded square pixel rect for a normalized Vision-space face box
    /// (bottom-left origin), flipped into CGImage's top-left space.
    static func facePixelRect(cg: CGImage, box: CGRect) -> CGRect {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let pad: CGFloat = 0.20
        var cx = box.midX * w
        var cy = box.midY * h
        var side = max(box.width, box.height) * max(w, h) * (1 + 2 * pad)
        side = min(side, min(w, h))
        cx = min(max(cx, side / 2), w - side / 2)
        cy = min(max(cy, side / 2), h - side / 2)
        var rect = CGRect(x: cx - side / 2, y: (h - cy) - side / 2, width: side, height: side)
        rect.origin.x = rect.origin.x.rounded()
        rect.origin.y = rect.origin.y.rounded()
        rect.size.width = rect.size.width.rounded()
        rect.size.height = rect.size.height.rounded()
        if rect.maxX > w { rect.origin.x = w - rect.width }
        if rect.maxY > h { rect.origin.y = h - rect.height }
        return rect
    }

    // MARK: - Clustering

    /// Assigns a face vector to the closest existing person (cosine similarity
    /// to the person's centroid); below threshold → new "Person N".
    private func bestPerson(for vec: [Float]) async -> String {
        let people = (try? await DatabaseManager.shared.allPeople()) ?? []
        var bestID: String?
        var bestSim = matchThreshold
        for p in people {
            let faces = (try? await DatabaseManager.shared.faces(forPerson: p.id)) ?? []
            guard let centroid = centroid(of: faces) else { continue }
            let sim = Self.cosine(vec, centroid)
            if sim > bestSim {
                bestSim = sim
                bestID = p.id
            }
        }
        if let bestID { return bestID }
        let person = PersonRecord(
            id: UUID().uuidString,
            name: "Person \(people.count + 1)",
            createdAt: Date()
        )
        try? await DatabaseManager.shared.savePerson(person)
        return person.id
    }

    /// Merges people whose centroids are nearly identical (the same person was
    /// split into two clusters by incremental assignment).
    private func mergePass() async {
        let people = (try? await DatabaseManager.shared.allPeople()) ?? []
        var merged = Set<String>()
        for a in people where !merged.contains(a.id) {
            let facesA = (try? await DatabaseManager.shared.faces(forPerson: a.id)) ?? []
            guard let ca = centroid(of: facesA) else { continue }
            for b in people where b.id != a.id && !merged.contains(b.id) {
                let facesB = (try? await DatabaseManager.shared.faces(forPerson: b.id)) ?? []
                guard let cb = centroid(of: facesB) else { continue }
                if Self.cosine(ca, cb) > mergeThreshold {
                    try? await DatabaseManager.shared.mergePerson(b.id, into: a.id)
                    merged.insert(b.id)
                }
            }
        }
    }

    /// Average of member vectors — the cluster centroid.
    private func centroid(of faces: [FaceRecord]) -> [Float]? {
        guard let first = faces.first else { return nil }
        let dim = Self.floats(from: first.vectorData).count
        guard dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        var count = 0
        for f in faces {
            let v = Self.floats(from: f.vectorData)
            guard v.count == dim else { continue }
            for i in 0..<dim { sum[i] += v[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        let norm = sqrtf(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return sum.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, a.count > 0 else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<a.count {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    static func floats(from data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Face thumbnails (persistent — outside the evictable thumbs dir)

    static func facesDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("xCloud/faces", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func faceThumbURL(objectID: String, faceID: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? Self.facesDirectory() else { return nil }
        let url = dir.appendingPathComponent("\(objectID)-\(faceID).jpg")
        return fm.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Square crop centered on the face (20% padding), downscaled to 128px.
    private func saveFaceThumb(cg: CGImage, box: CGRect, objectID: String, faceID: String) {
        let rect = Self.facePixelRect(cg: cg, box: box)
        guard let cropped = cg.cropping(to: rect) else { return }

        let target = 128
        guard let ctx = CGContext(
            data: nil, width: target, height: target,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let out = ctx.makeImage() else { return }
        let img = NSImage(cgImage: out, size: NSSize(width: target, height: target))
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              let dir = try? Self.facesDirectory() else { return }
        try? jpg.write(to: dir.appendingPathComponent("\(objectID)-\(faceID).jpg"))
    }

    // MARK: - Cleanup

    /// Drops faces (and thumbnails) for a deleted object.
    func deleteFaces(for objectID: String) async {
        for face in (try? await DatabaseManager.shared.faces(for: objectID)) ?? [] {
            if let url = faceThumbURL(objectID: objectID, faceID: face.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? await DatabaseManager.shared.deleteFaces(forObjectID: objectID)
    }

    // MARK: - Queries for UI

    func faces(for objectID: String) async -> [FaceRecord] {
        (try? await DatabaseManager.shared.faces(for: objectID)) ?? []
    }

    func facesByObject(for objectIDs: [String]) async -> [String: [FaceRecord]] {
        (try? await DatabaseManager.shared.faces(forObjectIDs: objectIDs)) ?? [:]
    }

    func people() async -> [(PersonRecord, Int)] {
        (try? await DatabaseManager.shared.peopleWithFaceCounts()) ?? []
    }

    func person(id: String) async -> PersonRecord? {
        try? await DatabaseManager.shared.person(id: id)
    }

    /// First face thumbnail of a person — the avatar for People chips.
    func personAvatarURL(_ personID: String) async -> URL? {
        let faces = (try? await DatabaseManager.shared.faces(forPerson: personID)) ?? []
        for face in faces {
            if let url = faceThumbURL(objectID: face.objectID, faceID: face.id) {
                return url
            }
        }
        return nil
    }

    // MARK: - User corrections

    /// Names a face: creates a person for unmatched faces, renames the cluster
    /// for matched ones. Bumps the change notification so the UI refreshes.
    func nameFace(_ faceID: String, name: String) async {
        guard let face = try? await DatabaseManager.shared.face(id: faceID) else { return }
        var personID = face.personID
        if personID == nil {
            let p = PersonRecord(id: UUID().uuidString, name: name, createdAt: Date())
            try? await DatabaseManager.shared.savePerson(p)
            personID = p.id
            try? await DatabaseManager.shared.assignFace(face.id, to: p.id)
        }
        if let personID {
            try? await DatabaseManager.shared.setPersonName(personID, name: name)
        }
        await notifyChanged()
    }

    func renamePerson(_ personID: String, name: String) async {
        try? await DatabaseManager.shared.setPersonName(personID, name: name)
        await notifyChanged()
    }

    func mergePeople(from fromID: String, into toID: String) async {
        try? await DatabaseManager.shared.mergePerson(fromID, into: toID)
        await notifyChanged()
    }

    /// Posts the change notification (main thread) so the Photos UI reloads.
    func notifyChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .xcPhotoIndexed, object: nil)
        }
    }
}

extension Notification.Name {
    /// Fired whenever face indexing or people data changes.
    static let xcPhotoIndexed = Notification.Name("xc.photoIndexed")
}