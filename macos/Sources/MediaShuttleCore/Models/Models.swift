import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case jpeg
    case raw
    case otherPhoto
    case video

    public var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .raw: "RAW"
        case .otherPhoto: "OTHER"
        case .video: "VIDEO"
        }
    }

    public var destinationComponents: [String] {
        switch self {
        case .jpeg: ["Photos", "JPEGs"]
        case .raw: ["Photos", "RAWs"]
        case .otherPhoto: ["Photos", "Other"]
        case .video: ["Videos"]
        }
    }
}

public enum OperationPhase: String, Codable, Sendable {
    case idle
    case scanning
    case checkingDuplicate
    case copying
    case verifying
    case reVerifying
    case erasing
    case complete
    case cancelled
    case error

    /// Phases that report continuously within a single file, rather than once per state change.
    /// These are the only ones worth rate-limiting on the way to the UI; every other phase arrives
    /// a handful of times per operation and has to be shown as soon as it does.
    public var isContinuous: Bool {
        self == .copying || self == .reVerifying
    }

    public var label: String {
        switch self {
        case .idle: "STANDBY"
        case .scanning: "SCANNING"
        case .checkingDuplicate: "CHECKING"
        case .copying: "COPYING"
        case .verifying: "VERIFYING"
        case .reVerifying: "RE-VERIFYING"
        case .erasing: "ERASING"
        case .complete: "VERIFIED"
        case .cancelled: "CANCELLED"
        case .error: "NEEDS ATTENTION"
        }
    }
}

public struct MediaItem: Codable, Hashable, Sendable {
    public let sourceURL: URL
    public let fileName: String
    public let fileExtension: String
    public let size: Int64
    public let modifiedAt: Date
    public let kind: MediaKind

    public init(
        sourceURL: URL,
        fileName: String,
        fileExtension: String,
        size: Int64,
        modifiedAt: Date,
        kind: MediaKind
    ) {
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.size = size
        self.modifiedAt = modifiedAt
        self.kind = kind
    }
}

public struct CardScan: Sendable {
    public let media: [MediaItem]
    public let unverifiableFiles: [URL]

    public init(media: [MediaItem], unverifiableFiles: [URL]) {
        self.media = media
        self.unverifiableFiles = unverifiableFiles
    }
}

public struct CardInfo: Codable, Hashable, Identifiable, Sendable {
    public let rootURL: URL
    public let volumeLabel: String
    public let volumeID: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let driveType: String

    public var id: String { volumeID + "|" + rootURL.path }
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public init(
        rootURL: URL,
        volumeLabel: String,
        volumeID: String,
        totalBytes: Int64,
        freeBytes: Int64,
        driveType: String
    ) {
        self.rootURL = rootURL
        self.volumeLabel = volumeLabel
        self.volumeID = volumeID
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.driveType = driveType
    }
}

public struct TransferRecord: Codable, Hashable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let sha256: String
    public let size: Int64
    public let kind: MediaKind

    public init(sourceURL: URL, destinationURL: URL, sha256: String, size: Int64, kind: MediaKind) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sha256 = sha256
        self.size = size
        self.kind = kind
    }
}

public struct TransferSession: Codable, Hashable, Sendable {
    public var sessionID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public var startedAt: Date = .now
    public var completedAt: Date?
    public var erasedAt: Date?
    public var status: String = "In progress"
    public var sourceRoot: URL
    public var sourceLabel: String
    public var sourceVolumeID: String
    public var destinationRoot: URL
    public var totalFiles: Int
    public var totalBytes: Int64
    public var copiedCount: Int = 0
    public var skippedCount: Int = 0
    public var erasedFileCount: Int = 0
    public var files: [TransferRecord] = []

    public init(card: CardInfo, destinationRoot: URL, totalFiles: Int, totalBytes: Int64) {
        sourceRoot = card.rootURL
        sourceLabel = card.volumeLabel
        sourceVolumeID = card.volumeID
        self.destinationRoot = destinationRoot
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
    }

    public func isEligibleForErase(card: CardInfo, media: [MediaItem]) -> Bool {
        guard status.caseInsensitiveCompare("Verified") == .orderedSame,
              sourceRoot.standardizedFileURL.path == card.rootURL.standardizedFileURL.path,
              sourceVolumeID == card.volumeID,
              files.count == media.count,
              !files.isEmpty else {
            return false
        }

        var recordsBySource: [String: TransferRecord] = [:]
        recordsBySource.reserveCapacity(files.count)
        for record in files {
            let sourcePath = record.sourceURL.standardizedFileURL.path
            guard recordsBySource.updateValue(record, forKey: sourcePath) == nil else {
                return false
            }
        }

        for item in media {
            guard let record = recordsBySource[item.sourceURL.standardizedFileURL.path],
                  record.size == item.size,
                  Self.isSafeDestination(record.destinationURL, outside: card.rootURL),
                  Self.fileSize(at: record.destinationURL) == record.size else {
                return false
            }
        }
        return true
    }

    private static func isSafeDestination(_ destination: URL, outside cardRoot: URL) -> Bool {
        let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            return false
        }

        let cardPath = cardRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let cardPrefix = cardPath.hasSuffix("/") ? cardPath : cardPath + "/"
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return destinationPath != cardPath && !destinationPath.hasPrefix(cardPrefix)
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }
}

public struct OperationProgress: Sendable {
    public let phase: OperationPhase
    public let currentItem: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let processedBytes: Int64
    public let totalBytes: Int64
    public let copiedFiles: Int
    public let skippedFiles: Int
    public let currentSourceURL: URL?
    public let currentDestinationFolder: String

    public init(
        phase: OperationPhase,
        currentItem: String,
        completedFiles: Int,
        totalFiles: Int,
        processedBytes: Int64,
        totalBytes: Int64,
        copiedFiles: Int = 0,
        skippedFiles: Int = 0,
        currentSourceURL: URL? = nil,
        currentDestinationFolder: String = ""
    ) {
        self.phase = phase
        self.currentItem = currentItem
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.copiedFiles = copiedFiles
        self.skippedFiles = skippedFiles
        self.currentSourceURL = currentSourceURL
        self.currentDestinationFolder = currentDestinationFolder
    }

    public var fraction: Double {
        if totalBytes > 0 {
            return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
        }
        guard totalFiles > 0 else { return 0 }
        return min(max(Double(completedFiles) / Double(totalFiles), 0), 1)
    }
}

public struct TransferResult: Sendable {
    public let session: TransferSession
    public let sessionFileURL: URL
}

public struct WipeResult: Sendable {
    public let deletedFiles: Int
    public let protectedSystemEntries: [String]
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var autoTransfer = false
    public var groupByDate = false
    public var showNotifications = true
    public var showActivityLog = true
    public var destinationPath = ""
    /// The interface is designed dark; System and Light remain available in Settings.
    public var appearance = "Dark"
    /// Hands every verified transfer to Apple Photos once it finishes, so it reaches iCloud Photos.
    public var addToPhotosAfterTransfer = false
    /// RAW files are added as the RAW half of a RAW+JPEG pair, or on their own when no JPEG exists.
    public var photosIncludeRaw = true
    public var photosIncludeVideos = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case autoTransfer, groupByDate, showNotifications, showActivityLog, destinationPath, appearance
        case addToPhotosAfterTransfer, photosIncludeRaw, photosIncludeVideos
    }

    /// Every key is optional. The synthesized decoder rejected the whole file whenever it lacked a
    /// key, so the first launch of a build that adds a setting threw away every saved one — the
    /// destination included, which then fell back to ~/Desktop/Camera and was recreated there.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        autoTransfer = try container.decodeIfPresent(Bool.self, forKey: .autoTransfer) ?? defaults.autoTransfer
        groupByDate = try container.decodeIfPresent(Bool.self, forKey: .groupByDate) ?? defaults.groupByDate
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications)
            ?? defaults.showNotifications
        showActivityLog = try container.decodeIfPresent(Bool.self, forKey: .showActivityLog)
            ?? defaults.showActivityLog
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)
            ?? defaults.destinationPath
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? defaults.appearance
        addToPhotosAfterTransfer = try container.decodeIfPresent(Bool.self, forKey: .addToPhotosAfterTransfer)
            ?? defaults.addToPhotosAfterTransfer
        photosIncludeRaw = try container.decodeIfPresent(Bool.self, forKey: .photosIncludeRaw)
            ?? defaults.photosIncludeRaw
        photosIncludeVideos = try container.decodeIfPresent(Bool.self, forKey: .photosIncludeVideos)
            ?? defaults.photosIncludeVideos
    }
}

public enum MediaShuttleError: LocalizedError, Equatable {
    case noSupportedMedia
    case insufficientSpace
    case destinationUnavailable
    case eraseLocked
    case cardChanged
    case unsafePath
    case sourceChanged(String)
    case verificationFailed(String)
    case eraseBlocked(String)
    public var errorDescription: String? {
        switch self {
        case .noSupportedMedia:
            "No supported photos or videos were found on this card."
        case .insufficientSpace:
            "Not enough free space at the destination. Free up room for the new files plus 1 GB, or choose another destination."
        case .destinationUnavailable:
            "The destination folder is unavailable. Choose another folder and try again."
        case .eraseLocked:
            "Erase is available only after a completed, verified transfer."
        case .cardChanged:
            "The connected card does not match the verified transfer."
        case .unsafePath:
            "A safety check rejected a path outside the selected card."
        case .verificationFailed(let name):
            "SHA-256 verification failed for \(name)."
        case .sourceChanged(let name):
            "\(name) changed while it was being copied. Re-scan the card and try again."
        case .eraseBlocked(let reason):
            "Erase blocked: \(reason)"
        }
    }
}
