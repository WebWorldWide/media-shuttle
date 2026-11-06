import Foundation

/// One asset to create in Apple Photos. A RAW file shot alongside a JPEG becomes a single RAW+JPEG
/// asset, the same pairing Photos makes when it imports from a camera itself, rather than two
/// unrelated photos of the same moment.
public struct PhotosImportItem: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case photo
        case video
    }

    public let kind: Kind
    /// The JPEG/HEIC (or the RAW, when it has no JPEG partner), or the video.
    public let primaryURL: URL
    /// The RAW half of a RAW+JPEG pair, added as the asset's alternate photo resource.
    public let pairedRawURL: URL?
    /// Destination SHA-256 of every file in the asset, recorded once Photos accepts it so the same
    /// files are not added a second time by the next import.
    public let hashes: [String]

    public var displayName: String { primaryURL.lastPathComponent }
}

public struct PhotosImportPlan: Sendable {
    public let items: [PhotosImportItem]
    /// Files already handed to Photos by an earlier import.
    public let alreadyInPhotos: Int
    /// Formats Photos cannot take, such as BRAW, R3D, MXF or AVCHD streams.
    public let unsupported: [URL]
    /// Left out by the RAW or video preference.
    public let excludedBySettings: Int
    /// Destination copies that no longer exist (moved or deleted since the transfer).
    public let missing: [URL]

    public var fileCount: Int {
        items.reduce(0) { $0 + ($1.pairedRawURL == nil ? 1 : 2) }
    }
}

public enum PhotosImportPlanner {
    // What PhotoKit accepts as a resource. Everything else the classifier copies is left out and
    // reported, instead of failing a batch inside Photos.
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe",
        "heic", "heif", "hif", "avif",
        "png", "tif", "tiff", "gif", "webp", "bmp", "jxl"
    ]

    // ARRIRAW is a cinema format with no system decoder; the rest are read by macOS's RAW engine.
    static let unsupportedRawExtensions: Set<String> = ["ari"]

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]

    public static func plan(
        records: [TransferRecord],
        includeRaw: Bool,
        includeVideos: Bool,
        alreadyImported: Set<String>,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> PhotosImportPlan {
        var unsupported: [URL] = []
        var missing: [URL] = []
        var excluded = 0
        var already = 0

        // Pair by the file's folder and name on the card, which is where the camera put the pair.
        // Destination names can differ — a collision may have renamed one half.
        struct PairKey: Hashable {
            let folder: String
            let stem: String
        }
        var order: [PairKey] = []
        var groups: [PairKey: [TransferRecord]] = [:]
        var videos: [TransferRecord] = []
        var seenHashes: Set<String> = []

        for record in records {
            let hash = record.sha256.uppercased()
            // The same bytes twice in one session (a file duplicated on the card) is one asset.
            guard seenHashes.insert(hash).inserted else { continue }
            let ext = record.destinationURL.pathExtension.lowercased()

            switch record.kind {
            case .video:
                guard includeVideos else { excluded += 1; continue }
                guard videoExtensions.contains(ext) else { unsupported.append(record.destinationURL); continue }
                videos.append(record)
            case .raw:
                guard !unsupportedRawExtensions.contains(ext) else {
                    unsupported.append(record.destinationURL)
                    continue
                }
                fallthrough
            case .jpeg, .otherPhoto:
                if record.kind != .raw, !photoExtensions.contains(ext) {
                    unsupported.append(record.destinationURL)
                    continue
                }
                let source = record.sourceURL.standardizedFileURL
                let key = PairKey(
                    folder: source.deletingLastPathComponent().path.lowercased(),
                    stem: source.deletingPathExtension().lastPathComponent.lowercased()
                )
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(record)
            }
        }

        var items: [PhotosImportItem] = []

        func admit(_ records: [TransferRecord], make: ([TransferRecord]) -> PhotosImportItem?) {
            let present = records.filter { record in
                if fileExists(record.destinationURL) { return true }
                missing.append(record.destinationURL)
                return false
            }
            guard !present.isEmpty else { return }
            if present.allSatisfy({ alreadyImported.contains($0.sha256.uppercased()) }) {
                already += present.count
                return
            }
            if let item = make(present) { items.append(item) }
        }

        for key in order {
            let group = groups[key] ?? []
            let rendered = group.first { $0.kind != .raw }
            let raw = group.first { $0.kind == .raw }
            // Extra renditions under the same name (a HEIC beside the JPEG) become their own assets.
            let extras = group.filter { $0 != rendered && $0 != raw }

            var members: [TransferRecord] = []
            if let rendered { members.append(rendered) }
            if let raw {
                if includeRaw { members.append(raw) } else { excluded += 1 }
            }
            admit(members) { present in
                let primary = present.first { $0.kind != .raw } ?? present[0]
                let pairedRaw = present.first { $0.kind == .raw && $0 != primary }
                return PhotosImportItem(
                    kind: .photo,
                    primaryURL: primary.destinationURL,
                    pairedRawURL: pairedRaw?.destinationURL,
                    hashes: present.map { $0.sha256.uppercased() }
                )
            }
            for extra in extras {
                if extra.kind == .raw, !includeRaw { excluded += 1; continue }
                admit([extra]) { present in
                    PhotosImportItem(
                        kind: .photo,
                        primaryURL: present[0].destinationURL,
                        pairedRawURL: nil,
                        hashes: [present[0].sha256.uppercased()]
                    )
                }
            }
        }

        for video in videos {
            admit([video]) { present in
                PhotosImportItem(
                    kind: .video,
                    primaryURL: present[0].destinationURL,
                    pairedRawURL: nil,
                    hashes: [present[0].sha256.uppercased()]
                )
            }
        }

        return PhotosImportPlan(
            items: items,
            alreadyInPhotos: already,
            unsupported: unsupported,
            excludedBySettings: excluded,
            missing: missing
        )
    }
}
