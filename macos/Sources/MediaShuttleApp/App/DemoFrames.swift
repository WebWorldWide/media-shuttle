#if DEBUG
import AppKit
import MediaShuttleCore
import SwiftUI

/// Debug-only: renders the real main window through a scripted ingest — card arrives, transfer,
/// verified, added to Photos — as PNG frames plus a `frames.txt` concat list with each frame's hold
/// time. `docs/video/build.sh` turns those into the product footage for the promo video.
///
///     MediaShuttle --screenshot --render-demo-frames <dir>
///
/// `--screenshot` keeps `AppModel.start()` from scanning real volumes while this runs.
@MainActor
enum DemoFrames {
    static let windowSize = CGSize(width: 1_280, height: 720)

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--render-demo-frames"), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Renderer(directory: directory).run()
        exit(0)
    }

    @MainActor
    private final class Renderer {
        let directory: URL
        let model = AppModel()
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        var frames: [(name: String, hold: Double)] = []

        // A fixed clock, so activity timestamps read like a real afternoon rather than the build time.
        let base = Calendar.current.date(bySettingHour: 14, minute: 32, second: 6, of: .now) ?? .now

        let card = CardInfo(
            rootURL: URL(fileURLWithPath: "/Volumes/LEXAR", isDirectory: true),
            volumeLabel: "LEXAR",
            volumeID: "media-shuttle-demo",
            totalBytes: 64_000_000_000,
            freeBytes: 53_900_000_000,
            driveType: "Removable media"
        )

        init(directory: URL) {
            self.directory = directory
            model.settings.appearance = "Dark"
            hosting = NSHostingView(rootView: AnyView(
                ContentView(model: model).environment(\.colorScheme, .dark)
            ))
            window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: DemoFrames.windowSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.frame = CGRect(origin: .zero, size: DemoFrames.windowSize)
            window.orderFrontRegardless()
        }

        func run() {
            let media = makeMedia()
            let totalBytes = media.reduce(Int64(0)) { $0 + $1.size }
            let simulatedSeconds = 128.0

            // 1 · Waiting for a card. `--screenshot` seeds a finished transfer; start from nothing.
            model.currentCard = nil
            model.media = []
            model.verifiedSession = nil
            model.banner = nil
            model.isBusy = false
            model.operationStartedAt = nil
            model.operationEndedAt = nil
            model.topStatus = "WAITING FOR MEDIA"
            model.statusTone = .neutral
            model.primaryActionTitle = "Scan for media"
            model.progress = OperationProgress(
                phase: .idle, currentItem: "Waiting for camera media",
                completedFiles: 0, totalFiles: 0, processedBytes: 0, totalBytes: 0
            )
            model.activities = [entry(0, "Watching for camera cards.")]
            capture(hold: 1.6)

            // 2 · The card is detected.
            model.currentCard = card
            model.media = media
            model.topStatus = "LEXAR CONNECTED"
            model.statusTone = .active
            model.primaryActionTitle = "Transfer and verify"
            model.activities.insert(entry(41, "Detected LEXAR at /Volumes/LEXAR"), at: 0)
            capture(hold: 1.6)

            // 3 · Transfer and verify.
            model.isBusy = true
            model.topStatus = "TRANSFER ACTIVE"
            model.primaryActionTitle = "Transferring…"
            model.activities.insert(entry(43, "Transfer started from /Volumes/LEXAR"), at: 0)
            let steps = 56
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let completed = min(media.count - 1, Int((Double(media.count) * fraction).rounded(.down)))
                let item = media[completed]
                let done = Int((Double(media.count) * fraction).rounded(.down))
                let skipped = min(15, done / 30)
                model.operationStartedAt = Date.now.addingTimeInterval(-simulatedSeconds * fraction)
                model.operationEndedAt = nil
                model.progress = OperationProgress(
                    phase: step % 7 == 6 ? .verifying : .copying,
                    currentItem: item.fileName,
                    completedFiles: done,
                    totalFiles: media.count,
                    processedBytes: Int64(Double(totalBytes) * fraction),
                    totalBytes: totalBytes,
                    copiedFiles: done - skipped,
                    skippedFiles: skipped,
                    currentSourceURL: item.sourceURL,
                    currentDestinationFolder: item.kind == .raw ? "Photos/RAWs" : "Photos/JPEGs"
                )
                capture(hold: step == steps ? 0.3 : 0.1)
            }

            // 4 · Verified.
            var session = TransferSession(
                card: card,
                destinationRoot: model.destinationURL,
                totalFiles: media.count,
                totalBytes: totalBytes
            )
            session.status = "Verified"
            session.completedAt = base.addingTimeInterval(171)
            session.copiedCount = 442
            session.skippedCount = 15
            session.files = media.map {
                TransferRecord(
                    sourceURL: $0.sourceURL,
                    destinationURL: model.destinationURL.appendingPathComponent($0.fileName),
                    sha256: String(repeating: "A", count: 64),
                    size: $0.size,
                    kind: $0.kind
                )
            }
            model.isBusy = false
            model.verifiedSession = session
            model.operationStartedAt = Date.now.addingTimeInterval(-simulatedSeconds)
            model.operationEndedAt = .now
            model.topStatus = "LEXAR · TRANSFER VERIFIED"
            model.statusTone = .verified
            model.primaryActionTitle = "Transfer again"
            model.progress = OperationProgress(
                phase: .complete,
                currentItem: "Verified report ready",
                completedFiles: media.count,
                totalFiles: media.count,
                processedBytes: totalBytes,
                totalBytes: totalBytes,
                copiedFiles: 442,
                skippedFiles: 15,
                currentSourceURL: media.last?.sourceURL,
                currentDestinationFolder: "Photos/JPEGs"
            )
            model.banner = BannerMessage(
                title: "Transfer verified",
                message: "457 files copied and checked with SHA-256.",
                tone: .success
            )
            model.activities.insert(entry(171, "Verified 457 files: 442 copied, 15 already at the destination."), at: 0)
            capture(hold: 2.4)

            // 5 · Add to Apple Photos.
            model.activities.insert(entry(176, "Adding LEXAR to Apple Photos."), at: 0)
            let photoItems = 418
            for step in 0...20 {
                model.photosProgress = PhotosImportProgress(completed: photoItems * step / 20, total: photoItems)
                capture(hold: 0.12)
            }
            model.photosProgress = nil
            let summary = "418 items added (457 files, RAW+JPEG paired)."
            model.banner = BannerMessage(title: "Added to Photos", message: summary, tone: .success)
            model.activities.insert(entry(204, "Added to Photos. \(summary)"), at: 0)
            capture(hold: 3.2)

            writeConcatList()
            renderMenuBarPanel(media: media, totalBytes: totalBytes)
            snapshot(SettingsView(model: model), name: "settings.png")
            snapshot(EraseConfirmationView(model: model, onConfirm: {}, onCancel: {}), name: "erase.png")
        }

        /// A single view at its natural size, for checking the design outside the main window.
        private func snapshot<V: View>(_ content: V, name: String) {
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
            let size = view.fittingSize
            window.setContentSize(size)
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            RunLoop.main.run(until: .now.addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }

        /// The menu bar panel mid-transfer with Photos filling, for the website.
        private func renderMenuBarPanel(media: [MediaItem], totalBytes: Int64) {
            let panelModel = AppModel()
            panelModel.settings.appearance = "Dark"
            panelModel.settings.autoTransfer = true
            panelModel.settings.addToPhotosAfterTransfer = true
            panelModel.currentCard = card
            panelModel.media = media
            panelModel.verifiedSession = nil
            panelModel.banner = nil
            panelModel.isBusy = true
            panelModel.topStatus = "TRANSFER ACTIVE"
            panelModel.statusTone = .active
            panelModel.operationStartedAt = Date.now.addingTimeInterval(-79)
            panelModel.progress = OperationProgress(
                phase: .copying, currentItem: "DSC01262.JPG", completedFiles: 284, totalFiles: media.count,
                processedBytes: Int64(Double(totalBytes) * 0.62), totalBytes: totalBytes,
                copiedFiles: 280, skippedFiles: 4
            )
            panelModel.photosProgress = PhotosImportProgress(completed: 48, total: 418)
            panelModel.activities = [
                entry(43, "Transfer started from /Volumes/LEXAR"),
                entry(41, "Detected LEXAR at /Volumes/LEXAR")
            ]
            let view = NSHostingView(rootView: MenuBarView(model: panelModel).environment(\.colorScheme, .dark))
            let size = view.fittingSize
            window.setContentSize(size)
            window.contentView = view
            view.frame = CGRect(origin: .zero, size: size)
            RunLoop.main.run(until: .now.addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("menubar.png"))
        }

        private func makeMedia() -> [MediaItem] {
            let folder = card.rootURL.appendingPathComponent("DCIM/100MSDCF", isDirectory: true)
            var items: [MediaItem] = []
            for index in 0..<418 {
                let name = String(format: "DSC%05d.JPG", 1_000 + index)
                items.append(MediaItem(
                    sourceURL: folder.appendingPathComponent(name), fileName: name, fileExtension: "jpg",
                    size: 21_400_000, modifiedAt: base, kind: .jpeg
                ))
                if index % 10 == 0, index < 390 {
                    let raw = String(format: "DSC%05d.ARW", 1_000 + index)
                    items.append(MediaItem(
                        sourceURL: folder.appendingPathComponent(raw), fileName: raw, fileExtension: "arw",
                        size: 29_500_000, modifiedAt: base, kind: .raw
                    ))
                }
            }
            return items
        }

        private func entry(_ offset: TimeInterval, _ message: String) -> ActivityEntry {
            ActivityEntry(date: base.addingTimeInterval(offset), message: message)
        }

        private func capture(hold: Double) {
            // Let Observation deliver the change and SwiftUI lay it out before drawing.
            RunLoop.main.run(until: .now.addingTimeInterval(0.08))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let name = String(format: "frame-%04d.png", frames.count)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            frames.append((name, hold))
        }

        private func writeConcatList() {
            var lines = ["ffconcat version 1.0"]
            for frame in frames {
                lines.append("file '\(frame.name)'")
                lines.append("duration \(frame.hold)")
            }
            // The concat demuxer drops the last duration unless the final file is listed again.
            if let last = frames.last { lines.append("file '\(last.name)'") }
            try? lines.joined(separator: "\n").write(
                to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8
            )
            let total = frames.reduce(0) { $0 + $1.hold }
            print("rendered \(frames.count) frames, \(String(format: "%.2f", total))s of footage")
        }
    }
}
#endif
