import Foundation
import XCTest
@testable import MediaShuttleCore

final class MediaShuttleCoreTests: XCTestCase {
    private var testRoot: URL!
    private var cardRoot: URL!
    private var destinationRoot: URL!
    private var stateRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaShuttleTests-\(UUID().uuidString)", isDirectory: true)
        cardRoot = testRoot.appendingPathComponent("CARD", isDirectory: true)
        destinationRoot = testRoot.appendingPathComponent("Camera", isDirectory: true)
        stateRoot = testRoot.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cardRoot.appendingPathComponent("DCIM/100MSDCF", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: testRoot.path)
            try FileManager.default.removeItem(at: testRoot)
        }
    }

    func testClassificationAndScanIgnoreAppleDoubleFiles() throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        let raw = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let video = cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let sidecar = cardRoot.appendingPathComponent("DCIM/100MSDCF/._DSC00001.JPG")
        try write("jpeg", to: jpeg)
        try write("raw", to: raw)
        try write("video", to: video)
        try write("metadata", to: sidecar)

        XCTAssertEqual(MediaClassifier.classify(jpeg), .jpeg)
        XCTAssertEqual(MediaClassifier.classify(raw), .raw)
        XCTAssertEqual(MediaClassifier.classify(video), .video)
        XCTAssertNil(MediaClassifier.classify(sidecar))

        for name in ["IMG.CR3", "IMG.CR2", "DSC.NEF", "DSCF.RAF", "P.ORF", "P.RW2", "X.PEF", "X.X3F"] {
            XCTAssertEqual(
                MediaClassifier.classify(URL(fileURLWithPath: name)),
                .raw,
                "\(name) is recognised as RAW"
            )
        }
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "A001.BRAW")), .video)
        XCTAssertTrue(MediaClassifier.isDisposableCameraArtifact(URL(fileURLWithPath: "INDEX.XML")))
        XCTAssertTrue(MediaClassifier.isDisposableCameraArtifact(URL(fileURLWithPath: "GOPR0001.THM")))
        XCTAssertFalse(MediaClassifier.isDisposableCameraArtifact(URL(fileURLWithPath: "NOTES.PDF")))

        let items = try MediaClassifier.scan(cardRoot)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.kind)), Set([.jpeg, .raw, .video]))
    }

    func testSelectedFolderTransferRequiresNoCameraLayout() async throws {
        let folder = testRoot.appendingPathComponent("Selected source", isDirectory: true)
        let jpeg = folder.appendingPathComponent("photo.JPG")
        try write("selected-folder-photo", to: jpeg)
        let card = try CardDetector.selectedSource(at: folder)
        XCTAssertEqual(card.rootURL, folder.resolvingSymlinksInPath())
        XCTAssertEqual(card.volumeLabel, "Selected source")
        XCTAssertEqual(card.driveType, "Selected folder")
        XCTAssertEqual(card.id, try CardDetector.selectedSource(at: folder).id)
        XCTAssertFalse(CardDetector.isCameraCardVolume(folder), "Selecting a folder must not grant card erase")
        XCTAssertThrowsError(try CardDetector.selectedSource(at: jpeg))
        XCTAssertThrowsError(try CardDetector.selectedSource(at: URL(fileURLWithPath: "/")))

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let result = try await transfer.transfer(
            card: card, destinationRoot: destinationRoot, groupByDate: false
        )
        XCTAssertEqual(result.session.totalFiles, 1)
        XCTAssertEqual(result.session.copiedCount, 1)
        let copied = try XCTUnwrap(result.session.files.first?.destinationURL)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: jpeg))
        let sourceHash = try await FileHasher.sha256(at: jpeg)
        let destinationHash = try await FileHasher.sha256(at: copied)
        XCTAssertEqual(sourceHash, destinationHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
    }

    func testTransferDoesNotRecreateMissingDestination() async throws {
        let missing = testRoot.appendingPathComponent("Removed Camera", isDirectory: true)
        let card = try CardDetector.selectedSource(at: cardRoot)
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)

        do {
            _ = try await transfer.transfer(card: card, destinationRoot: missing, groupByDate: false)
            XCTFail("Transfer should reject a missing destination")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileNoSuchFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSettingsRoundTripAndCardPresenceBaseline() async throws {
        let store = try StateStore(rootURL: stateRoot)
        var settings = AppSettings()
        settings.autoTransfer = true
        settings.groupByDate = true
        settings.showActivityLog = false
        settings.appearance = "Dark"
        settings.destinationPath = destinationRoot.path
        try await store.saveSettings(settings)
        let loaded = await store.loadSettings()
        XCTAssertEqual(loaded, settings)

        var tracker = CardPresenceTracker()
        XCTAssertFalse(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
        XCTAssertFalse(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
        XCTAssertFalse(tracker.observe(selectedRoot: nil, activeRoots: []))
        XCTAssertTrue(tracker.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))

        // A card inserted next to one already connected is still an arrival once it is the
        // selected card, even though another card held the selection when it was mounted.
        let secondCardRoot = testRoot.appendingPathComponent("SECOND-CARD", isDirectory: true)
        var alongside = CardPresenceTracker()
        XCTAssertFalse(alongside.observe(selectedRoot: cardRoot, activeRoots: [cardRoot]))
        XCTAssertFalse(alongside.observe(selectedRoot: cardRoot, activeRoots: [cardRoot, secondCardRoot]))
        XCTAssertTrue(
            alongside.observe(selectedRoot: secondCardRoot, activeRoots: [cardRoot, secondCardRoot]),
            "A card mounted while another was selected is an arrival when it becomes selected"
        )

        // Everything mounted at the first scan is the baseline, selected or not.
        var atStartup = CardPresenceTracker()
        XCTAssertFalse(atStartup.observe(selectedRoot: cardRoot, activeRoots: [cardRoot, secondCardRoot]))
        XCTAssertFalse(
            atStartup.observe(selectedRoot: secondCardRoot, activeRoots: [secondCardRoot]),
            "A second card present at startup is not an arrival when it becomes selected"
        )
    }

    func testVerifiedTransferDuplicatesCollisionsAndSafeErase() async throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        let raw = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let video = cardRoot.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let appleDouble = cardRoot.appendingPathComponent("DCIM/100MSDCF/._DSC00001.JPG")
        try write("jpeg-one", to: jpeg)
        try write("raw-one", to: raw)
        try write("video-one", to: video)
        try write("metadata", to: appleDouble)
        try write("camera database", to: cardRoot.appendingPathComponent("INDEX.XML"))

        // An unfinished copy from an earlier run sits where the app writes; a look-alike at the
        // destination root is not the app's and is left alone.
        let ownedPartial = destinationRoot.appendingPathComponent(
            "Photos/JPEGs/orphan.JPG.partial-0123456789abcdef0123456789abcdef"
        )
        let unrelatedPartial = destinationRoot.appendingPathComponent("keep.partial-draft")
        let rootLookalike = destinationRoot.appendingPathComponent(
            "mine.JPG.partial-0123456789abcdef0123456789abcdef"
        )
        try write("stale", to: ownedPartial)
        try write("keep", to: unrelatedPartial)
        try write("mine", to: rootLookalike)

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let wipe = WipeService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )

        let first = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(first.session.status, "Verified")
        XCTAssertEqual(first.session.copiedCount, 3)
        XCTAssertEqual(first.session.skippedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/JPEGs/DSC00001.JPG").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/RAWs/DSC00001.ARW").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Videos/C0001.MP4").path
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationRoot.appendingPathComponent("Photos/Other").path
            ),
            "No folder is created for a category the card has no files in"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootLookalike.path))

        let duplicate = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(duplicate.session.copiedCount, 0)
        XCTAssertEqual(duplicate.session.skippedCount, 3)

        try write("jpeg-two", to: jpeg)
        let collision = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        XCTAssertEqual(collision.session.copiedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Photos/JPEGs/DSC00001 (2).JPG").path
        ))

        let unverified = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC99999.JPG")
        try write("new file", to: unverified)
        do {
            _ = try await wipe.wipe(card: card, session: collision.session)
            XCTFail("Erase should be blocked by media added after transfer")
        } catch let error as MediaShuttleError {
            guard case .eraseBlocked = error else {
                return XCTFail("Unexpected safety error: \(error)")
            }
        }

        // A format the classifier does not know is never copied, so erase has nothing to verify it
        // against and must refuse the whole card rather than delete it.
        let unknownFormat = cardRoot.appendingPathComponent("DCIM/100MSDCF/CLIP0001.XYZ")
        try write("an unrecognised camera format", to: unknownFormat)
        XCTAssertEqual(try MediaClassifier.unverifiableFiles(at: cardRoot).count, 1)
        do {
            _ = try await wipe.wipe(card: card, session: collision.session)
            XCTFail("Erase should be blocked by content no transfer could have copied")
        } catch let error as MediaShuttleError {
            guard case .eraseBlocked = error else {
                return XCTFail("Unexpected safety error: \(error)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unknownFormat.path),
            "A blocked erase leaves unrecognised content untouched"
        )
        try FileManager.default.removeItem(at: unknownFormat)
        XCTAssertEqual(
            try MediaClassifier.unverifiableFiles(at: cardRoot).count,
            0,
            "Camera housekeeping alone does not block erase"
        )

        let finalTransfer = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        let nestedDatabase = cardRoot.appendingPathComponent("PRIVATE/CAMERA_DB/NESTED/INDEX.BDM")
        try write("database", to: nestedDatabase)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: nestedDatabase.path)

        let result = try await wipe.wipe(card: card, session: finalTransfer.session)
        XCTAssertGreaterThanOrEqual(result.deletedFiles, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cardRoot.path), [])
        let latestSession = await store.latestVerifiedSession(for: card)
        XCTAssertNil(latestSession)
    }

    func testEraseRefusesOrdinaryFilesAndNestedExcludedFolders() async throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try write("jpeg", to: jpeg)
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let wipe = WipeService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot, volumeLabel: "TEST CARD", volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024, freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )
        let result = try await transfer.transfer(
            card: card, destinationRoot: destinationRoot, groupByDate: false
        )
        let paths = [
            "notes.txt", "PRIVATE/settings.dat", "PRIVATE/backup.bin", "DCIM/library.db",
            "project.ini", "package.inf", "notes.log",
            "DCIM/.Trashes/notes.xyz", "DCIM/Archive.bundle/Contents/notes.xyz"
        ]
        for path in paths {
            let unverified = cardRoot.appendingPathComponent(path)
            try write("user content without a destination copy", to: unverified)
            XCTAssertEqual(try MediaClassifier.unverifiableFiles(at: cardRoot), [unverified], path)
            do {
                _ = try await wipe.wipe(card: card, session: result.session)
                XCTFail("Erase must refuse unverified content: \(path)")
                return
            } catch let error as MediaShuttleError {
                guard case .eraseBlocked = error else {
                    return XCTFail("Unexpected safety error: \(error)")
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unverified.path))
            try FileManager.default.removeItem(at: unverified)
        }
    }

    func testEraseEligibilityLocksWhenSourceOrDestinationChanges() async throws {
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try write("jpeg", to: jpeg)
        let database = cardRoot.appendingPathComponent("INDEX.XML")
        try write("camera database", to: database)

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let wipe = WipeService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )

        let result = try await transfer.transfer(
            card: card,
            destinationRoot: destinationRoot,
            groupByDate: false
        )
        let scanned = try MediaClassifier.scan(cardRoot)
        XCTAssertTrue(result.session.isEligibleForErase(card: card, media: scanned))

        let destination = try XCTUnwrap(result.session.files.first?.destinationURL)
        try FileManager.default.removeItem(at: destination)
        XCTAssertFalse(result.session.isEligibleForErase(card: card, media: scanned))

        try write("jpeg", to: destination)
        XCTAssertTrue(result.session.isEligibleForErase(card: card, media: scanned))

        try FileManager.default.removeItem(at: jpeg)
        XCTAssertFalse(
            result.session.isEligibleForErase(card: card, media: try MediaClassifier.scan(cardRoot))
        )
        do {
            _ = try await wipe.wipe(card: card, session: result.session)
            XCTFail("Erase should be blocked when a transferred source file disappears")
        } catch let error as MediaShuttleError {
            guard case .eraseBlocked = error else {
                return XCTFail("Unexpected safety error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    func testTransferRejectsDestinationInsideCard() async throws {
        try write("jpeg", to: cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"))
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )
        let unsafeDestination = cardRoot.appendingPathComponent("Backup", isDirectory: true)

        do {
            _ = try await transfer.transfer(
                card: card,
                destinationRoot: unsafeDestination,
                groupByDate: false
            )
            XCTFail("Transfer should reject a destination inside the source card")
        } catch let error as MediaShuttleError {
            XCTAssertEqual(error, .unsafePath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeDestination.path))

        let photos = destinationRoot.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: photos.appendingPathComponent("JPEGs", isDirectory: true),
            withDestinationURL: cardRoot.appendingPathComponent("DCIM", isDirectory: true)
        )
        do {
            _ = try await transfer.transfer(
                card: card,
                destinationRoot: destinationRoot,
                groupByDate: false
            )
            XCTFail("Transfer should reject a category folder that resolves outside the destination")
        } catch let error as MediaShuttleError {
            XCTAssertEqual(error, .unsafePath)
        }
    }

    /// The app sits in the menu bar for months and logs a line per file, so app.log is bounded by
    /// a single rollover. Losing the rollover means an unbounded file in Application Support.
    func testLogRollsOverOnceOversizedAndKeepsPreviousRun() async throws {
        let logger = try AppLogger(stateRoot: stateRoot)
        let manager = FileManager.default

        await logger.write("first run")
        XCTAssertTrue(manager.fileExists(atPath: logger.logURL.path))
        XCTAssertFalse(manager.fileExists(atPath: logger.previousLogURL.path))

        // Stand in for months of transfers rather than writing two megabytes a line at a time.
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: logger.logURL)

        await logger.write("after rollover")

        let current = try String(contentsOf: logger.logURL, encoding: .utf8)
        XCTAssertTrue(current.contains("after rollover"))
        XCTAssertLessThan(current.count, 1024, "the rolled-over log should start fresh")

        let previous = try Data(contentsOf: logger.previousLogURL)
        XCTAssertEqual(previous.count, 2 * 1024 * 1024, "the oversized log is kept as the previous run")

        // A second rollover replaces the previous log rather than accumulating more of them.
        try Data(repeating: 0x42, count: 2 * 1024 * 1024).write(to: logger.logURL)
        await logger.write("second rollover")
        XCTAssertEqual(
            try Data(contentsOf: logger.previousLogURL).first,
            0x42,
            "only the most recent oversized log is retained"
        )
        let stateEntries = try manager.contentsOfDirectory(atPath: stateRoot.path)
            .filter { $0.hasPrefix("app") && $0.hasSuffix(".log") }
        XCTAssertEqual(Set(stateEntries), ["app.log", "app.previous.log"])
    }

    /// Events are handed to the logger without being awaited, so the line has to carry the time the
    /// event happened rather than the time it reached the file.
    func testLogLineCarriesTheEventTimeItWasGiven() async throws {
        let logger = try AppLogger(stateRoot: stateRoot)
        let moment = Date(timeIntervalSince1970: 1_700_000_000)

        await logger.write("Detected UNTITLED at /Volumes/UNTITLED", at: moment)

        let contents = try String(contentsOf: logger.logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(moment.ISO8601Format()))
        XCTAssertTrue(contents.contains("Detected UNTITLED at /Volumes/UNTITLED"))
    }

    /// Only the phases that report continuously within one file may be rate-limited on the way to
    /// the UI; rate-limiting any other phase would drop a state change that is reported once.
    func testOnlyContinuousPhasesAreRateLimited() {
        XCTAssertTrue(OperationPhase.copying.isContinuous)
        XCTAssertTrue(OperationPhase.reVerifying.isContinuous)
        for phase in [
            OperationPhase.idle, .scanning, .checkingDuplicate, .verifying,
            .erasing, .complete, .cancelled, .error
        ] {
            XCTAssertFalse(phase.isContinuous, "\(phase) is reported once and must not be coalesced")
        }
    }

    func testSettingsMissingNewerKeysKeepEverythingSaved() async throws {
        // A settings file written before the Photos options existed.
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let legacy = """
        {
          "appearance" : "Light",
          "autoTransfer" : true,
          "destinationPath" : "\(destinationRoot.path)",
          "groupByDate" : true,
          "showActivityLog" : false,
          "showNotifications" : false
        }
        """
        let store = try StateStore(rootURL: stateRoot)
        try Data(legacy.utf8).write(to: await store.settingsURL)
        let loaded = await store.loadSettings()
        XCTAssertEqual(loaded.destinationPath, destinationRoot.path, "The saved destination survives an upgrade")
        XCTAssertTrue(loaded.autoTransfer)
        XCTAssertTrue(loaded.groupByDate)
        XCTAssertFalse(loaded.showActivityLog)
        XCTAssertFalse(loaded.showNotifications)
        XCTAssertEqual(loaded.appearance, "Light")
        XCTAssertFalse(loaded.addToPhotosAfterTransfer)
        XCTAssertTrue(loaded.photosIncludeRaw)
        XCTAssertTrue(loaded.photosIncludeVideos)

        var updated = loaded
        updated.addToPhotosAfterTransfer = true
        updated.photosIncludeVideos = false
        try await store.saveSettings(updated)
        let reloaded = await store.loadSettings()
        XCTAssertEqual(reloaded, updated)
    }

    func testRepeatTransferReusesEarlierCollisionCopies() async throws {
        let sameSize = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        let otherSize = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00002.JPG")
        try write("card-one", to: sameSize)
        try write("card-two-is-longer", to: otherSize)
        // Different files already at the destination under the same names.
        let jpegs = destinationRoot.appendingPathComponent("Photos/JPEGs", isDirectory: true)
        try write("desk-one", to: jpegs.appendingPathComponent("DSC00001.JPG"))
        try write("short", to: jpegs.appendingPathComponent("DSC00002.JPG"))

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )

        let first = try await transfer.transfer(card: card, destinationRoot: destinationRoot, groupByDate: false)
        XCTAssertEqual(first.session.copiedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpegs.appendingPathComponent("DSC00001 (2).JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpegs.appendingPathComponent("DSC00002 (2).JPG").path))

        let second = try await transfer.transfer(card: card, destinationRoot: destinationRoot, groupByDate: false)
        XCTAssertEqual(second.session.copiedCount, 0, "Both files were already safe under their (2) names")
        XCTAssertEqual(second.session.skippedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpegs.appendingPathComponent("DSC00001 (3).JPG").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpegs.appendingPathComponent("DSC00002 (3).JPG").path))
        XCTAssertEqual(
            Set(second.session.files.map(\.destinationURL.lastPathComponent)),
            ["DSC00001 (2).JPG", "DSC00002 (2).JPG"]
        )
        XCTAssertTrue(second.session.isEligibleForErase(card: card, media: try MediaClassifier.scan(cardRoot)))
    }

    func testPhotosPlanPairsRawWithJpegAndSkipsWhatPhotosCannotTake() throws {
        let folder = cardRoot.appendingPathComponent("DCIM/100MSDCF", isDirectory: true)
        func record(_ name: String, _ kind: MediaKind, _ hash: String, destination: String? = nil) -> TransferRecord {
            TransferRecord(
                sourceURL: folder.appendingPathComponent(name),
                destinationURL: destinationRoot.appendingPathComponent(destination ?? name),
                sha256: hash,
                size: 10,
                kind: kind
            )
        }
        let records = [
            record("DSC00001.JPG", .jpeg, "a1"),
            record("DSC00001.ARW", .raw, "a2"),
            record("DSC00002.ARW", .raw, "b1"),
            record("DSC00003.JPG", .jpeg, "c1", destination: "DSC00003 (2).JPG"),
            record("C0001.MP4", .video, "d1"),
            record("A001.BRAW", .video, "e1"),
            record("00001.MTS", .video, "e2"),
            record("PSD0001.PSD", .otherPhoto, "f1"),
            record("COPY.JPG", .jpeg, "C1"),
            record("GONE.JPG", .jpeg, "g1"),
            record("OLD.JPG", .jpeg, "h1")
        ]
        let missing = destinationRoot.appendingPathComponent("GONE.JPG")
        let plan = PhotosImportPlanner.plan(
            records: records,
            includeRaw: true,
            includeVideos: true,
            alreadyImported: ["H1"],
            fileExists: { $0 != missing }
        )

        XCTAssertEqual(plan.items.count, 4)
        let pair = try XCTUnwrap(plan.items.first { $0.primaryURL.lastPathComponent == "DSC00001.JPG" })
        XCTAssertEqual(pair.pairedRawURL?.lastPathComponent, "DSC00001.ARW")
        XCTAssertEqual(pair.hashes, ["A1", "A2"])
        let lonelyRaw = try XCTUnwrap(plan.items.first { $0.primaryURL.lastPathComponent == "DSC00002.ARW" })
        XCTAssertNil(lonelyRaw.pairedRawURL)
        XCTAssertTrue(plan.items.contains { $0.primaryURL.lastPathComponent == "DSC00003 (2).JPG" })
        XCTAssertEqual(plan.items.first { $0.kind == .video }?.primaryURL.lastPathComponent, "C0001.MP4")
        XCTAssertEqual(
            Set(plan.unsupported.map(\.lastPathComponent)),
            ["A001.BRAW", "00001.MTS", "PSD0001.PSD"]
        )
        XCTAssertEqual(plan.missing.map(\.lastPathComponent), ["GONE.JPG"])
        XCTAssertEqual(plan.alreadyInPhotos, 1)
        XCTAssertEqual(plan.fileCount, 5)

        let noRawNoVideo = PhotosImportPlanner.plan(
            records: records,
            includeRaw: false,
            includeVideos: false,
            alreadyImported: ["H1"],
            fileExists: { $0 != missing }
        )
        XCTAssertEqual(
            noRawNoVideo.items.map(\.primaryURL.lastPathComponent).sorted(),
            ["DSC00001.JPG", "DSC00003 (2).JPG"]
        )
        XCTAssertNil(noRawNoVideo.items.first?.pairedRawURL)
        XCTAssertEqual(noRawNoVideo.excludedBySettings, 5, "Two RAWs and three videos")
    }

    func testPhotosLedgerAndLatestCompletedSessionPersist() async throws {
        let store = try StateStore(rootURL: stateRoot)
        let initial = await store.photosImportedHashes()
        XCTAssertTrue(initial.isEmpty)
        try await store.recordPhotosImported(["ab12", "CD34"])
        try await store.recordPhotosImported(["AB12", "ef56"])
        let hashes = await store.photosImportedHashes()
        XCTAssertEqual(hashes, ["AB12", "CD34", "EF56"])

        let none = await store.latestCompletedSession()
        XCTAssertNil(none)
        let jpeg = cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try write("jpeg", to: jpeg)
        let logger = try AppLogger(stateRoot: stateRoot)
        let card = CardInfo(
            rootURL: cardRoot,
            volumeLabel: "TEST CARD",
            volumeID: "test-volume",
            totalBytes: 64 * 1_024 * 1_024,
            freeBytes: 32 * 1_024 * 1_024,
            driveType: "Removable media"
        )
        let result = try await TransferService(stateStore: store, logger: logger)
            .transfer(card: card, destinationRoot: destinationRoot, groupByDate: false)
        let latest = await store.latestCompletedSession()
        XCTAssertEqual(latest?.sessionID, result.session.sessionID)
    }

    // MARK: Slow or failing drives

    func testWriteFailureNamesTheFileAndSaysWhy() async throws {
        try write("jpeg-one", to: cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"))
        let jpegFolder = destinationRoot.appendingPathComponent("Photos/JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: jpegFolder, withIntermediateDirectories: true)
        // Read-only folder: the first write fails the way an unplugged or write-protected drive does.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: jpegFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jpegFolder.path) }

        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot, volumeLabel: "CARD", volumeID: "v", totalBytes: 1, freeBytes: 1, driveType: "Removable media"
        )

        do {
            _ = try await transfer.transfer(card: card, destinationRoot: destinationRoot, groupByDate: false)
            XCTFail("expected the write to fail")
        } catch let error as MediaShuttleError {
            guard case .writeFailed(let file, _) = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual(file, "DSC00001.JPG")
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("DSC00001.JPG"), text)
            XCTAssertFalse(text.contains("The file couldn’t be saved"), text)
        }
    }

    func testPlainReasonExplainsPosixCodes() {
        func wrapped(_ code: Int32) -> Error {
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            return NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                           userInfo: [NSUnderlyingErrorKey: posix])
        }
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(ENOSPC)).contains("full"))
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(ENXIO)).contains("disconnected"))
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(EIO)).contains("hardware"))
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(EACCES)).contains("allow"))
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(EFBIG)).contains("too large"))
        // Unknown codes fall back to Foundation's text, with a full stop.
        XCTAssertTrue(MediaShuttleError.plainReason(for: wrapped(EINTR)).hasSuffix("."))
    }

    func testCopyReportsPerFileProgressThroughVerification() async throws {
        try write(String(repeating: "x", count: 300_000), to: cardRoot.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"))
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)
        let card = CardInfo(
            rootURL: cardRoot, volumeLabel: "CARD", volumeID: "v", totalBytes: 1, freeBytes: 1, driveType: "Removable media"
        )
        let seen = ProgressSink()
        _ = try await transfer.transfer(card: card, destinationRoot: destinationRoot, groupByDate: false) { update in
            await seen.append(update)
        }
        let updates = await seen.updates
        let copying = updates.filter { $0.phase == .copying }
        XCTAssertEqual(copying.first?.currentItemFraction, 0)
        XCTAssertEqual(copying.last?.currentItemFraction, 1)
        XCTAssertTrue(updates.contains { $0.phase == .verifying && $0.currentItemFraction == 0 })
        XCTAssertTrue(updates.allSatisfy { ($0.currentItemFraction ?? 0) <= 1 })
    }

    /// Runs the real transfer against real drives. Skipped unless both paths are given:
    ///
    ///     MEDIA_SHUTTLE_REAL_SOURCE=/Volumes/CARD MEDIA_SHUTTLE_REAL_DESTINATION=/Volumes/Drive/Test \
    ///         swift test --package-path macos --filter testRealDrives
    func testRealDrives() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MEDIA_SHUTTLE_REAL_SOURCE"],
              let destinationPath = environment["MEDIA_SHUTTLE_REAL_DESTINATION"] else {
            throw XCTSkip("set MEDIA_SHUTTLE_REAL_SOURCE and MEDIA_SHUTTLE_REAL_DESTINATION to run")
        }
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let card = try CardDetector.selectedSource(at: URL(fileURLWithPath: sourcePath, isDirectory: true))
        let store = try StateStore(rootURL: stateRoot)
        let logger = try AppLogger(stateRoot: stateRoot)
        let transfer = TransferService(stateStore: store, logger: logger)

        let seen = ProgressSink()
        let started = Date.now
        let result = try await transfer.transfer(card: card, destinationRoot: destination, groupByDate: false) { update in
            await seen.append(update)
        }
        let updates = await seen.updates
        let elapsed = Date.now.timeIntervalSince(started)
        let verifying = updates.filter { $0.phase == .verifying && ($0.currentItemFraction ?? 0) > 0 }
        print("REAL: \(result.session.totalFiles) files, \(result.session.copiedCount) copied, "
              + "\(result.session.skippedCount) already safe, \(ByteCountFormatter.string(fromByteCount: result.session.totalBytes, countStyle: .file)) "
              + "in \(Int(elapsed)) s; \(updates.count) progress reports, \(verifying.count) mid-verify")
        print("REAL LOG:\n" + ((try? String(contentsOf: logger.logURL, encoding: .utf8)) ?? ""))
        XCTAssertEqual(result.session.status, "Verified")
        XCTAssertEqual(result.session.copiedCount + result.session.skippedCount, result.session.totalFiles)
    }

    private actor ProgressSink {

        var updates: [OperationProgress] = []
        func append(_ update: OperationProgress) { updates.append(update) }
    }
    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }
}
