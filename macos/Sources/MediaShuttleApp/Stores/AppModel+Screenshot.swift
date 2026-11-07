#if DEBUG
import Foundation
import MediaShuttleCore

extension AppModel {
    func configureScreenshotState() {
        settings.appearance = "Dark"
        let card = CardInfo(
            rootURL: URL(fileURLWithPath: "/Volumes/LEXAR", isDirectory: true),
            volumeLabel: "LEXAR",
            volumeID: "media-shuttle-screenshot",
            totalBytes: 64_000_000_000,
            freeBytes: 53_900_000_000,
            driveType: "Removable media"
        )
        let baseFolder = card.rootURL.appendingPathComponent("DCIM/100MSDCF", isDirectory: true)
        let jpegs = (0..<418).map { index in
            MediaItem(
                sourceURL: baseFolder.appendingPathComponent(String(format: "DSC%05d.JPG", index)),
                fileName: String(format: "DSC%05d.JPG", index),
                fileExtension: "jpg",
                size: 22_000_000,
                modifiedAt: .now,
                kind: .jpeg
            )
        }
        let raws = (0..<39).map { index in
            MediaItem(
                sourceURL: baseFolder.appendingPathComponent(String(format: "DSC%05d.ARW", index)),
                fileName: String(format: "DSC%05d.ARW", index),
                fileExtension: "arw",
                size: 24_000_000,
                modifiedAt: .now,
                kind: .raw
            )
        }
        let last = jpegs[381]
        var session = TransferSession(
            card: card,
            destinationRoot: destinationURL,
            totalFiles: 457,
            totalBytes: 10_100_000_000
        )
        session.status = "Verified"
        session.completedAt = .now
        session.copiedCount = 442
        session.skippedCount = 15
        session.files = [
            TransferRecord(
                sourceURL: last.sourceURL,
                destinationURL: destinationURL.appendingPathComponent("Photos/JPEGs/DSC00381.JPG"),
                sha256: String(repeating: "A", count: 64),
                size: last.size,
                kind: .jpeg
            )
        ]

        currentCard = card
        media = jpegs + raws
        verifiedSession = session
        progress = OperationProgress(
            phase: .complete,
            currentItem: "Verified report ready",
            completedFiles: 457,
            totalFiles: 457,
            processedBytes: 10_100_000_000,
            totalBytes: 10_100_000_000,
            copiedFiles: 442,
            skippedFiles: 15,
            currentSourceURL: last.sourceURL,
            currentDestinationFolder: "Photos/JPEGs"
        )
        topStatus = "LEXAR · TRANSFER VERIFIED"
        statusTone = .verified
        banner = BannerMessage(
            title: "Transfer verified",
            message: "457 files copied and checked with SHA-256.",
            tone: .success
        )
        primaryActionTitle = "Transfer again"
        operationStartedAt = Date.now.addingTimeInterval(-122)
        activities = [
            ActivityEntry(date: .now.addingTimeInterval(-3), message: "Verified 457 files: 442 copied, 15 already at the destination."),
            ActivityEntry(date: .now.addingTimeInterval(-122), message: "Transfer started from /Volumes/LEXAR.")
        ]
    }
}
#endif
