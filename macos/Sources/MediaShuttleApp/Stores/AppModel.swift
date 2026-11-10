import AppKit
import Foundation
import MediaShuttleCore
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppStatusTone: Sendable {
    case neutral
    case active
    case verified
    case warning
    case error
}

enum BannerTone: Sendable {
    case info
    case success
    case warning
    case error
}

struct BannerMessage: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let tone: BannerTone
}

struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String
}

struct PhotosImportProgress: Equatable, Sendable {
    var completed: Int
    var total: Int

    var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }
}

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings()
    var destinationURL: URL
    var currentCard: CardInfo?
    private(set) var selectedSourceURL: URL?
    private(set) var sourceAllowsErase = true
    var media: [MediaItem] = []
    var unverifiableFileCount = 0
    var verifiedSession: TransferSession?
    var reportURL: URL?
    var progress = OperationProgress(
        phase: .idle,
        currentItem: "Waiting for camera media",
        completedFiles: 0,
        totalFiles: 0,
        processedBytes: 0,
        totalBytes: 0
    )
    var activities: [ActivityEntry] = []
    var banner: BannerMessage?
    var isBusy = false
    var isDestinationAvailable = true
    var topStatus = "WAITING FOR MEDIA"
    var statusTone: AppStatusTone = .neutral
    var primaryActionTitle = "Scan for media"
    var operationStartedAt: Date?
    var operationEndedAt: Date?
    var isStarted = false
    var startupEnabled = SMAppService.mainApp.status == .enabled
    /// The newest verified transfer, kept after its card is erased or removed so its destination
    /// copies can still be added to Photos.
    var lastCompletedSession: TransferSession?
    /// Non-nil while an Add to Photos is running.
    var photosProgress: PhotosImportProgress?
    private(set) var currentCardIsEjectable = false
    /// Set from the menu bar, which cannot present the typed erase confirmation itself; the main
    /// window observes it and opens the sheet.
    var eraseRequested = false

    @ObservationIgnored private let stateStore: StateStore
    @ObservationIgnored private let logger: AppLogger
    @ObservationIgnored private let transferService: TransferService
    @ObservationIgnored private let wipeService: WipeService
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var presenceTracker = CardPresenceTracker()
    @ObservationIgnored private var lastScanSignature: String?
    @ObservationIgnored private var lastProgressAppliedAt: Date?
    @ObservationIgnored private var photosTask: Task<Void, Never>?
    /// When bytes last moved, whatever the redraw throttle did with the report. Read on the one-second
    /// tick to tell a slow drive from a dead one.
    @ObservationIgnored private var lastProgressReceivedAt: Date?
    @ObservationIgnored private var stallWatchTask: Task<Void, Never>?
    @ObservationIgnored private var stallAnnounced = false
    /// Set when the reader chose to quit during an operation; the app finishes quitting once the
    /// cancelled operation has cleaned up.
    @ObservationIgnored private var quitWhenOperationEnds = false

    init() {
        let applicationSupport = (try? StateStore.defaultRootURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Media Shuttle", isDirectory: true)
        do {
            let store = try StateStore(rootURL: applicationSupport)
            let appLogger = try AppLogger(stateRoot: applicationSupport)
            stateStore = store
            logger = appLogger
            transferService = TransferService(stateStore: store, logger: appLogger)
            wipeService = WipeService(stateStore: store, logger: appLogger)
        } catch {
            fatalError("Media Shuttle could not create its local state directory: \(error.localizedDescription)")
        }
        destinationURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("Camera", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot") {
            configureScreenshotState()
        }
        #endif
    }

    deinit {
        scanTask?.cancel()
        operationTask?.cancel()
        photosTask?.cancel()
        stallWatchTask?.cancel()
    }

    /// Seconds since the running operation last moved any bytes, once that pause is long enough to
    /// notice. Nil while idle, or while data is flowing.
    var stallSeconds: Int? {
        guard isBusy, let last = lastProgressReceivedAt else { return nil }
        let seconds = Int(Date.now.timeIntervalSince(last))
        return seconds >= Self.stallNoticeSeconds ? seconds : nil
    }

    private static let stallNoticeSeconds = 8
    private static let stallLogSeconds = 30

    /// A rough time to go, from the average rate so far. Nil until there is enough to go on.
    var estimatedSecondsRemaining: TimeInterval? {
        guard isBusy, progress.totalBytes > 0, progress.processedBytes > 0,
              let rate = throughputBytesPerSecond, rate > 0,
              progress.phase == .copying || progress.phase == .verifying || progress.phase == .checkingDuplicate
        else { return nil }
        let remaining = Double(progress.totalBytes - progress.processedBytes)
        return max(0, remaining / rate)
    }

    /// What the running operation is called, for the quit confirmation. Nil when nothing is running.
    var runningOperationName: String? {
        guard operationTask != nil else { return nil }
        switch progress.phase {
        case .erasing, .reVerifying: return "erase"
        default: return "transfer"
        }
    }

    /// Quit was confirmed during an operation. Cancel it, let it remove its unfinished copy, and
    /// finish quitting from the operation's completion.
    func cancelOperationAndQuit() {
        guard operationTask != nil else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        quitWhenOperationEnds = true
        operationTask?.cancel()
    }

    private func operationDidEnd() {
        operationEndedAt = .now
        isBusy = false
        operationTask = nil
        stallWatchTask?.cancel()
        stallWatchTask = nil
        lastProgressReceivedAt = nil
        // Reading the card does not move its free space, so let the next tick re-derive state
        // rather than have the skip-unchanged check hold on to what was true before this ran.
        lastScanSignature = nil
        if quitWhenOperationEnds {
            quitWhenOperationEnds = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Logs once per quiet spell when an operation has moved nothing for a while, so an unattended
    /// transfer that waited on a sleeping or unplugged drive leaves a trace in the activity log.
    private func startStallWatch() {
        stallWatchTask?.cancel()
        stallAnnounced = false
        lastProgressReceivedAt = .now
        stallWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.isBusy else { return }
                guard let last = self.lastProgressReceivedAt else { continue }
                let quiet = Int(Date.now.timeIntervalSince(last))
                if quiet >= Self.stallLogSeconds, !self.stallAnnounced {
                    self.stallAnnounced = true
                    self.addActivity(
                        "Nothing has moved for \(quiet) s. The card reader or destination drive may be slow, "
                            + "asleep or disconnected. The transfer is still waiting."
                    )
                } else if quiet < Self.stallNoticeSeconds, self.stallAnnounced {
                    self.stallAnnounced = false
                    self.addActivity("Data is moving again.")
                }
            }
        }
    }

    var isAddingToPhotos: Bool { photosProgress != nil }

    /// What Add to Photos works from: the connected card's verified transfer, else the newest one.
    var photosSession: TransferSession? { verifiedSession ?? lastCompletedSession }

    var canAddToPhotos: Bool { !isAddingToPhotos && photosSession != nil }

    var canEject: Bool { !isBusy && currentCard != nil && currentCardIsEjectable }

    var appearance: ColorScheme? {
        switch settings.appearance {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }

    var canTransfer: Bool {
        !isBusy && isDestinationAvailable && currentCard != nil && !media.isEmpty
    }

    /// WipeService refuses a card holding content no transfer could have copied. Reflected here so
    /// erase reads as locked, rather than accepting the typed confirmation and only then refusing.
    var canWipe: Bool {
        !isBusy && sourceAllowsErase && currentCard != nil
            && verifiedSession?.files.isEmpty == false && unverifiableFileCount == 0
    }

    var mediaCounts: [MediaKind: Int] {
        Dictionary(grouping: media, by: \.kind).mapValues(\.count)
    }

    var totalMediaBytes: Int64 {
        media.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Measured to the moment the operation finished, so the elapsed time and
    /// the throughput derived from it stop moving once a transfer is done.
    var elapsed: TimeInterval {
        guard let operationStartedAt else { return 0 }
        return (operationEndedAt ?? .now).timeIntervalSince(operationStartedAt)
    }

    var throughputBytesPerSecond: Double? {
        let elapsed = elapsed
        guard elapsed > 0, progress.processedBytes > 0 else { return nil }
        return Double(progress.processedBytes) / elapsed
    }

    func start() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot") {
            return
        }
#endif
        guard !isStarted else { return }
        isStarted = true
        settings = await stateStore.loadSettings()
        if !settings.destinationPath.isEmpty {
            destinationURL = URL(fileURLWithPath: settings.destinationPath, isDirectory: true).standardizedFileURL
        }
        prepareDestination(createIfMissing: settings.destinationPath.isEmpty)
        lastCompletedSession = await stateStore.latestCompletedSession()
        addActivity("Watching for camera cards.")
        await scanCards()

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.scanCards()
            }
        }
    }

    func scanNow() {
        Task { await scanCards(forceUpdate: true) }
    }

    func scanCards(forceUpdate: Bool = false) async {
        guard !isBusy else { return }
        let destination = destinationURL
        let chosenSource = selectedSourceURL
        let cards: [CardInfo]
        do {
            cards = try await Task.detached(priority: .utility) {
                if let chosenSource {
                    return [try CardDetector.selectedSource(at: chosenSource)]
                }
                return CardDetector.candidates(destinationRoot: destination)
            }.value
        } catch {
            guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
            resetSourceState()
            topStatus = "SOURCE UNAVAILABLE"
            statusTone = .error
            if banner?.title != "Source unavailable" {
                showError("Source unavailable", "Reconnect the selected source or choose another folder. " + error.localizedDescription)
            }
            return
        }
        guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
        let selected = cards.first
        let isNew = chosenSource == nil && presenceTracker.observe(
            selectedRoot: selected?.rootURL,
            activeRoots: cards.map(\.rootURL)
        )

        guard let card = selected else {
            if currentCard != nil || forceUpdate {
                currentCard = nil
                currentCardIsEjectable = false
                media = []
                unverifiableFileCount = 0
                lastScanSignature = nil
                verifiedSession = nil
                reportURL = nil
                updateDisconnectedState()
            }
            return
        }

        let previousCardID = currentCard?.id

        // This runs every two seconds for as long as a card stays connected. Walking the whole card
        // and re-reading every session report each time is minutes of pointless reader and disk
        // traffic on a full card, so skip it while the card looks untouched. Adding or removing
        // anything on a camera card moves the free-space figure, which is read fresh above.
        let signature = "\(card.rootURL.path)|\(card.volumeID)|\(card.freeBytes)"
        if !forceUpdate, !isNew, previousCardID == card.id, signature == lastScanSignature {
            return
        }
        let scan: CardScan
        do {
            scan = try await Task.detached(priority: .utility) {
                try MediaClassifier.scanCard(card.rootURL)
            }.value
        } catch {
            guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
            resetSourceState()
            showError("Source scan failed", error.localizedDescription)
            topStatus = "SOURCE SCAN FAILED"
            statusTone = .error
            return
        }
        guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
        let scanned = scan.media
        let storedSession = await stateStore.latestVerifiedSession(for: card)
        guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
        // Eligibility stats every destination copy, and the volume checks stat the card. On a USB
        // drive that has spun down, or a network share that has dropped, each of those can block
        // for seconds; done on the main actor they froze the whole window.
        let cardRootChanged = currentCard?.rootURL != card.rootURL
        let checks = await Task.detached(priority: .utility) {
            (
                session: storedSession.flatMap { $0.isEligibleForErase(card: card, media: scanned) ? $0 : nil },
                ejectable: cardRootChanged ? CardDetector.isEjectableVolumeRoot(card.rootURL) : nil,
                allowsErase: chosenSource == nil || CardDetector.isCameraCardVolume(card.rootURL)
            )
        }.value
        guard chosenSource == selectedSourceURL, destination == destinationURL, !isBusy else { return }
        lastScanSignature = signature
        let session = checks.session
        let sessionWasInvalidated = verifiedSession != nil && session == nil
        if let ejectable = checks.ejectable {
            currentCardIsEjectable = ejectable
        }
        currentCard = card
        if banner?.title == "Source unavailable" || banner?.title == "Source scan failed" {
            banner = nil
        }
        sourceAllowsErase = checks.allowsErase
        media = scanned
        unverifiableFileCount = scan.unverifiableFiles.count
        verifiedSession = session
        if let session {
            reportURL = await stateStore.sessionFileURL(for: session)
        } else {
            reportURL = nil
        }
        if session != nil {
            updateVerifiedState()
        } else if scanned.isEmpty {
            updateEmptyCardState()
        } else {
            updateDetectedState()
        }
        if sessionWasInvalidated {
            addActivity(
                "Card contents or destination copies changed. " +
                "Erase locked until the next verified transfer."
            )
        }

        if isNew || (forceUpdate && previousCardID != card.id) {
            addActivity("Detected \(card.volumeLabel) at \(card.rootURL.path)")
            if unverifiableFileCount > 0 {
                addActivity(
                    "\(unverifiableFileCount) file(s) on this card aren't camera media, so they can't be "
                    + "verified. Erase stays locked."
                )
            }
            if isNew, settings.autoTransfer, !scanned.isEmpty {
                if isDestinationAvailable {
                    startTransfer()
                } else {
                    // Unattended, this used to do nothing at all: no transfer, and nothing to say
                    // why when the reader came back to a card they expected to find copied.
                    addActivity("Automatic transfer skipped: the destination folder is unavailable.")
                    await sendNotification(
                        title: "Automatic transfer skipped",
                        body: "\(card.volumeLabel) was not copied because the destination folder is unavailable."
                    )
                }
            }
        }
    }

    func startTransfer() {
        guard operationTask == nil else { return }
        if isDestinationAvailable && !FileManager.default.fileExists(atPath: destinationURL.path) {
            isDestinationAvailable = false
        }
        guard isDestinationAvailable else {
            chooseDestination()
            return
        }
        guard let card = currentCard else {
            banner = BannerMessage(
                title: "No media source found",
                message: "Choose a source folder or connect a card containing DCIM, M4ROOT, or PRIVATE folders.",
                tone: .info
            )
            return
        }
        guard !media.isEmpty else {
            banner = BannerMessage(
                title: "No supported media found",
                message: "This card does not currently contain supported photos or videos.",
                tone: .info
            )
            return
        }

        isBusy = true
        operationStartedAt = .now
        operationEndedAt = nil
        banner = nil
        topStatus = "TRANSFER ACTIVE"
        statusTone = .active
        primaryActionTitle = "Transferring…"
        addActivity("Transfer started from \(card.rootURL.path)")
        startStallWatch()
        let destination = destinationURL
        let groupByDate = settings.groupByDate

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await transferService.transfer(
                    card: card,
                    destinationRoot: destination,
                    groupByDate: groupByDate,
                    progress: { [weak self] update in
                        await self?.apply(update)
                    }
                )
                verifiedSession = result.session
                lastCompletedSession = result.session
                reportURL = result.sessionFileURL
                updateVerifiedState()
                addActivity(
                    "Verified \(result.session.totalFiles) files: \(result.session.copiedCount) copied, " +
                    "\(result.session.skippedCount) already at the destination."
                )
                banner = BannerMessage(
                    title: "Transfer verified",
                    message: "\(result.session.totalFiles) files copied and checked with SHA-256.",
                    tone: .success
                )
                await sendNotification(
                    title: "Transfer verified",
                    body: "\(result.session.totalFiles) files copied and checked with SHA-256."
                )
                if settings.addToPhotosAfterTransfer {
                    addToPhotos(session: result.session)
                }
            } catch is CancellationError {
                progress = OperationProgress(
                    phase: .cancelled,
                    currentItem: "Transfer cancelled",
                    completedFiles: progress.completedFiles,
                    totalFiles: progress.totalFiles,
                    processedBytes: progress.processedBytes,
                    totalBytes: progress.totalBytes
                )
                topStatus = "TRANSFER CANCELLED"
                statusTone = .warning
                addActivity("Transfer cancelled.")
            } catch {
                progress = OperationProgress(
                    phase: .error,
                    currentItem: error.localizedDescription,
                    completedFiles: progress.completedFiles,
                    totalFiles: progress.totalFiles,
                    processedBytes: progress.processedBytes,
                    totalBytes: progress.totalBytes
                )
                showError("Transfer stopped", error.localizedDescription)
                topStatus = "NEEDS ATTENTION"
                statusTone = .error
                addActivity("Transfer stopped: \(error.localizedDescription)")
                // Automatic transfers run with the window closed, so a failure needs to reach the
                // reader the same way a success does.
                await sendNotification(title: "Transfer stopped", body: error.localizedDescription)
            }
            operationDidEnd()
            if verifiedSession == nil { primaryActionTitle = "Transfer and verify" }
        }
    }

    func cancelTransfer() {
        operationTask?.cancel()
    }

    /// The card and verified session the erase confirmation was opened against. The two-second scan
    /// keeps running while that sheet waits for input and can reassign both, so what is erased has
    /// to be checked against what was confirmed rather than against whatever is current on return.
    struct EraseTarget: Equatable, Sendable {
        let cardID: String
        let sessionID: String
    }

    var currentEraseTarget: EraseTarget? {
        guard canWipe, let card = currentCard, let session = verifiedSession else { return nil }
        return EraseTarget(cardID: card.id, sessionID: session.sessionID)
    }

    func wipeCard(expecting expected: EraseTarget) {
        guard sourceAllowsErase else {
            showError("Erase unavailable", "Erase is available only for camera-card volumes, not selected folders.")
            return
        }
        guard operationTask == nil else {
            showError(
                "Operation in progress",
                "A transfer started while the confirmation was open. Wait for it to finish, then erase the card."
            )
            addActivity("Erase cancelled: a transfer started during confirmation.")
            return
        }
        guard let card = currentCard,
              let session = verifiedSession,
              card.id == expected.cardID,
              session.sessionID == expected.sessionID else {
            showError(
                "Card changed",
                "The connected card changed while the confirmation was open. Reconnect it and try erasing again."
            )
            addActivity("Erase cancelled: the connected card changed during confirmation.")
            return
        }

        isBusy = true
        operationStartedAt = .now
        operationEndedAt = nil
        banner = nil
        topStatus = "ERASE ACTIVE"
        statusTone = .active
        addActivity("Erasing. Checking every file against its copy first.")
        startStallWatch()

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await wipeService.wipe(
                    card: card,
                    session: session,
                    progress: { [weak self] update in
                        await self?.apply(update)
                    }
                )
                verifiedSession = nil
                reportURL = nil
                media = []
                primaryActionTitle = "No media found"
                topStatus = "CARD EMPTY"
                statusTone = .verified
                addActivity("Erased \(result.deletedFiles) files from the card.")
                banner = BannerMessage(
                    title: "Card erased",
                    message: "\(result.deletedFiles) files deleted from the card.",
                    tone: .success
                )
                await sendNotification(
                    title: "Card erased",
                    body: "\(result.deletedFiles) files deleted from the card."
                )
            } catch {
                showError("Erase blocked", error.localizedDescription)
                topStatus = "ERASE BLOCKED"
                statusTone = .error
                addActivity("Erase blocked: \(error.localizedDescription)")
            }
            operationDidEnd()
        }
    }

    func chooseSource() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Media Source"
        panel.message = "Choose a camera-card volume or a folder containing photos and videos."
        panel.prompt = "Choose source"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentCard?.rootURL ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard !isBusy else { return }
        do {
            let source = try CardDetector.selectedSource(at: selected)
            guard !Self.isSameOrChild(destinationURL.resolvingSymlinksInPath(), of: source.rootURL) else {
                showError("Unsafe source", "Choose a source that does not contain the destination folder, or change the destination first.")
                return
            }
            selectedSourceURL = source.rootURL
            sourceAllowsErase = CardDetector.isCameraCardVolume(source.rootURL)
            resetSourceState()
            banner = nil
            topStatus = "SCANNING SOURCE"
            addActivity("Source selected: \(source.rootURL.path)")
            Task { await scanCards(forceUpdate: true) }
        } catch {
            showError("Source unavailable", error.localizedDescription)
        }
    }

    func useAutomaticSource() {
        guard !isBusy else { return }
        selectedSourceURL = nil
        sourceAllowsErase = true
        presenceTracker = CardPresenceTracker()
        resetSourceState()
        banner = nil
        addActivity("Automatic card detection enabled.")
        Task { await scanCards(forceUpdate: true) }
    }

    private func resetSourceState() {
        currentCard = nil
        currentCardIsEjectable = false
        media = []
        unverifiableFileCount = 0
        verifiedSession = nil
        reportURL = nil
        lastScanSignature = nil
        operationStartedAt = nil
        operationEndedAt = nil
        updateDisconnectedState()
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Media Destination"
        panel.message = "Photos and videos will be sorted into folders inside this location."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard !isBusy else { return }

        let selectedURL = selected.standardizedFileURL
        if let card = currentCard,
           Self.isSameOrChild(
               selectedURL.resolvingSymlinksInPath(),
               of: card.rootURL.resolvingSymlinksInPath()
           ) {
            showError("Unsafe destination", "Choose a folder that is not on the connected camera card.")
            return
        }
        destinationURL = selectedURL
        prepareDestination()
        guard isDestinationAvailable else { return }
        settings.destinationPath = selectedURL.path
        saveSettings()
        addActivity("Destination changed to \(selectedURL.path)")
        Task { await scanCards(forceUpdate: true) }
    }

    func openDestination() {
        NSWorkspace.shared.open(destinationURL)
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([reportURL])
    }

    func saveSettings() {
        let snapshot = settings
        Task {
            do {
                try await stateStore.saveSettings(snapshot)
            } catch {
                showError("Settings could not be saved", error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startupEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            startupEnabled = SMAppService.mainApp.status == .enabled
            showError(
                "Launch at Login could not be changed",
                "macOS may require the app to be moved to Applications before enabling this setting. " +
                    error.localizedDescription
            )
        }
    }

    func dismissBanner() {
        banner = nil
    }

    // MARK: Apple Photos

    func addToPhotos() {
        guard let session = photosSession else {
            banner = BannerMessage(
                title: "Nothing to add to Photos",
                message: "Transfer a card first. Photos gets the verified copies from the destination folder.",
                tone: .info
            )
            return
        }
        addToPhotos(session: session)
    }

    func cancelAddToPhotos() {
        photosTask?.cancel()
    }

    private func addToPhotos(session: TransferSession) {
        guard photosTask == nil else { return }
        let includeRaw = settings.photosIncludeRaw
        let includeVideos = settings.photosIncludeVideos
        let records = session.files
        let label = session.sourceLabel
        photosProgress = PhotosImportProgress(completed: 0, total: 0)
        addActivity("Adding \(label) to Apple Photos.")

        photosTask = Task { [weak self] in
            guard let self else { return }
            defer {
                photosProgress = nil
                photosTask = nil
            }
            do {
                try await PhotosImporter.requestAccess()
            } catch {
                showError("Photos access needed", error.localizedDescription)
                addActivity("Add to Photos stopped: \(error.localizedDescription)")
                return
            }

            let already = await stateStore.photosImportedHashes()
            let plan = await Task.detached(priority: .utility) {
                PhotosImportPlanner.plan(
                    records: records,
                    includeRaw: includeRaw,
                    includeVideos: includeVideos,
                    alreadyImported: already
                )
            }.value

            guard !plan.items.isEmpty else {
                let message = Self.photosSummary(plan: plan, outcome: nil)
                banner = BannerMessage(title: "Nothing new to add to Photos", message: message, tone: .info)
                addActivity("Add to Photos: nothing new. \(message)")
                return
            }

            let total = plan.items.count
            photosProgress = PhotosImportProgress(completed: 0, total: total)
            let store = stateStore
            let outcome = await PhotosImporter.add(plan.items) { [weak self] completed, hashes in
                self?.photosProgress = PhotosImportProgress(completed: completed, total: total)
                guard !hashes.isEmpty else { return }
                try? await store.recordPhotosImported(hashes)
            }

            let message = Self.photosSummary(plan: plan, outcome: outcome)
            let cancelled = Task.isCancelled
            let title: String
            let tone: BannerTone
            if cancelled {
                title = "Add to Photos cancelled"
                tone = .warning
            } else if !outcome.failures.isEmpty {
                title = outcome.addedItems > 0 ? "Added to Photos with problems" : "Photos did not accept these files"
                tone = outcome.addedItems > 0 ? .warning : .error
            } else {
                title = "Added to Photos"
                tone = .success
            }
            banner = BannerMessage(title: title, message: message, tone: tone)
            addActivity("\(title). \(message)")
            for failure in outcome.failures.prefix(5) {
                addActivity("Photos refused \(failure.name): \(failure.reason)")
            }
            if !cancelled {
                await sendNotification(title: title, body: message)
            }
        }
    }

    private static func photosSummary(plan: PhotosImportPlan, outcome: PhotosImporter.Outcome?) -> String {
        var parts: [String] = []
        if let outcome {
            let items = outcome.addedItems
            var added = "\(items) \(items == 1 ? "item" : "items") added"
            if outcome.addedFiles > items { added += " (\(outcome.addedFiles) files, RAW+JPEG paired)" }
            parts.append(added)
            if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) refused by Photos") }
        }
        if plan.alreadyInPhotos > 0 { parts.append("\(plan.alreadyInPhotos) already in Photos") }
        if !plan.unsupported.isEmpty {
            let formats = Set(plan.unsupported.map { $0.pathExtension.uppercased() }).sorted().joined(separator: ", ")
            parts.append("\(plan.unsupported.count) in formats Photos can't take (\(formats))")
        }
        if plan.excludedBySettings > 0 { parts.append("\(plan.excludedBySettings) skipped by your Photos settings") }
        if !plan.missing.isEmpty { parts.append("\(plan.missing.count) no longer at the destination") }
        return parts.isEmpty ? "No photos or videos in this transfer." : parts.joined(separator: " · ") + "."
    }

    func openPhotosApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Card

    func ejectCard() {
        guard canEject, let card = currentCard else { return }
        let root = card.rootURL
        let label = card.volumeLabel
        addActivity("Ejecting \(label).")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: root)
                }.value
                if let selectedSourceURL, selectedSourceURL.standardizedFileURL == root.standardizedFileURL {
                    self.selectedSourceURL = nil
                    sourceAllowsErase = true
                }
                resetSourceState()
                banner = BannerMessage(
                    title: "\(label) ejected",
                    message: "It is safe to remove the card.",
                    tone: .success
                )
                addActivity("Ejected \(label). Safe to remove.")
            } catch {
                showError(
                    "\(label) could not be ejected",
                    "Close any app or Finder window using the card and try again. " + error.localizedDescription
                )
            }
            await scanCards(forceUpdate: true)
        }
    }

    /// The typed confirmation lives in the main window; this asks it to open.
    func requestErase() {
        guard canWipe else { return }
        eraseRequested = true
    }

    func setAutoTransfer(_ enabled: Bool) {
        settings.autoTransfer = enabled
        saveSettings()
    }

    func setAddToPhotosAfterTransfer(_ enabled: Bool) {
        settings.addToPhotosAfterTransfer = enabled
        saveSettings()
        if enabled { preparePhotosAccess() }
    }

    /// Asks for Photos access when automatic adding is switched on, while the reader is here to
    /// answer. Left to the first automatic import, the prompt would wait, unseen, behind a transfer
    /// that ran with nobody at the Mac.
    func preparePhotosAccess() {
        Task {
            do {
                try await PhotosImporter.requestAccess()
            } catch {
                showError("Photos access needed", error.localizedDescription)
            }
        }
    }

    /// Create the default destination once. A missing saved destination stays unavailable until the
    /// user chooses a folder, so launching at login cannot recreate one they removed.
    private func prepareDestination(createIfMissing: Bool = false) {
        do {
            if createIfMissing {
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            isDestinationAvailable = true
            settings.destinationPath = destinationURL.path
            Task { try? await stateStore.saveSettings(settings) }
        } catch {
            isDestinationAvailable = false
            showError(
                "Destination unavailable",
                "The saved destination could not be opened. Choose an available folder before transferring."
            )
            topStatus = "CHOOSE A DESTINATION"
            statusTone = .error
        }
    }

    /// A copy reports every megabyte, so a fast reader produces hundreds of updates a second, each
    /// invalidating the whole progress region and competing with the transfer itself for the main
    /// actor. Coalesce to about fifteen redraws a second. Only mid-file progress is rate-limited:
    /// a change of phase or of file lands at once, so nothing the reader relies on is ever late,
    /// and a dropped update is always followed by one carrying the same totals.
    private static let progressRedrawInterval: TimeInterval = 1.0 / 15

    private func apply(_ update: OperationProgress) {
        lastProgressReceivedAt = .now
        let isContinuation = update.phase.isContinuous
            && update.phase == progress.phase
            && update.currentItem == progress.currentItem
        if isContinuation,
           let last = lastProgressAppliedAt,
           Date.now.timeIntervalSince(last) < Self.progressRedrawInterval {
            return
        }
        lastProgressAppliedAt = .now
        progress = update
    }

    private func updateDisconnectedState() {
        topStatus = "WAITING FOR MEDIA"
        statusTone = .neutral
        primaryActionTitle = "Scan for media"
        progress = OperationProgress(
            phase: .idle,
            currentItem: "Waiting for camera media",
            completedFiles: 0,
            totalFiles: 0,
            processedBytes: 0,
            totalBytes: 0
        )
    }

    private func updateDetectedState() {
        let state = selectedSourceURL == nil ? "CONNECTED" : "READY"
        topStatus = "\(currentCard?.volumeLabel.uppercased() ?? "MEDIA") \(state)"
        statusTone = .active
        primaryActionTitle = "Transfer and verify"
    }

    private func updateVerifiedState() {
        guard let session = verifiedSession else { return }
        topStatus = "\(currentCard?.volumeLabel.uppercased() ?? "CARD") · TRANSFER VERIFIED"
        statusTone = .verified
        primaryActionTitle = "Transfer again"
        progress = OperationProgress(
            phase: .complete,
            currentItem: "Verified report ready",
            completedFiles: session.totalFiles,
            totalFiles: session.totalFiles,
            processedBytes: session.totalBytes,
            totalBytes: session.totalBytes,
            copiedFiles: session.copiedCount,
            skippedFiles: session.skippedCount
        )
    }

    private func updateEmptyCardState() {
        topStatus = selectedSourceURL == nil ? "CARD EMPTY" : "SOURCE EMPTY"
        statusTone = .verified
        primaryActionTitle = "No media found"
    }

    private func showError(_ title: String, _ message: String) {
        banner = BannerMessage(title: title, message: message, tone: .error)
    }

    /// Mirrored to app.log. The window can be closed for an entire unattended transfer and this list
    /// dies with the process, so the log is the only record that a card arrived, what was done with
    /// it, and why an erase was refused.
    private func addActivity(_ message: String) {
        let entry = ActivityEntry(date: .now, message: message)
        activities.insert(entry, at: 0)
        if activities.count > 100 {
            activities.removeLast(activities.count - 100)
        }
        Task { await logger.write(message, at: entry.date) }
    }

    private func sendNotification(title: String, body: String) async {
        guard settings.showNotifications, Bundle.isPackagedApp else { return }
        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private static func isSameOrChild(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == root.standardizedFileURL.path || candidatePath.hasPrefix(rootPath)
    }
}
