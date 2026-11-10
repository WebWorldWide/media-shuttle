import Foundation

public actor WipeService {
    public typealias ProgressHandler = @Sendable (OperationProgress) async -> Void

    private let stateStore: StateStore
    private let logger: AppLogger

    public init(stateStore: StateStore, logger: AppLogger) {
        self.stateStore = stateStore
        self.logger = logger
    }

    public func wipe(
        card: CardInfo,
        session: TransferSession,
        progress: ProgressHandler? = nil
    ) async throws -> WipeResult {
        try validate(card: card, session: session)
        let root = card.rootURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MediaShuttleError.cardChanged
        }

        // A transfer only copies files the classifier recognises as camera media, so any other user
        // content on the card has no destination copy to verify against. Deleting it anyway would
        // lose it permanently, so fail closed: the card must hold nothing but recognised media and
        // camera/OS housekeeping before erase will touch it.
        let scan = try MediaClassifier.scanCard(root)
        guard scan.unverifiableFiles.isEmpty else {
            let names = scan.unverifiableFiles.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            throw MediaShuttleError.eraseBlocked(
                "\(scan.unverifiableFiles.count) file(s) on this card are not recognised camera media, "
                + "so no verified copy exists for them: \(names). "
                + "Copy them off the card yourself before erasing."
            )
        }

        let currentMedia = scan.media
        guard session.isEligibleForErase(card: card, media: currentMedia) else {
            throw MediaShuttleError.eraseBlocked(
                "the card contents or destination copies changed after the verified transfer. Transfer again first."
            )
        }
        let records = Dictionary(uniqueKeysWithValues: session.files.map {
            ($0.sourceURL.standardizedFileURL.path, $0)
        })
        let totalBytes = currentMedia.reduce(Int64(0)) { $0 + $1.size }
        var processedBytes: Int64 = 0
        var verifiedFiles = 0

        await logger.write("Re-verifying all remaining card media before erase")
        for item in currentMedia {
            try Task.checkCancellation()
            guard let record = records[item.sourceURL.standardizedFileURL.path] else {
                throw MediaShuttleError.eraseBlocked(
                    "\(item.fileName) was not part of the verified transfer. Transfer the card again first."
                )
            }
            // Each of these says what to do about it. "The destination copy changed size" on its own
            // leaves erase locked with nothing the card's owner can act on, and the answer is the
            // same every time: transfer again, which re-verifies the file and records it afresh.
            guard FileManager.default.fileExists(atPath: record.destinationURL.path) else {
                throw MediaShuttleError.eraseBlocked(
                    "the destination copy of \(item.fileName) is missing. "
                    + "Transfer this card again to restore it, then erase."
                )
            }
            guard fileSize(at: record.destinationURL) == record.size else {
                throw MediaShuttleError.eraseBlocked(
                    "the destination copy of \(item.fileName) is no longer the size it was verified at. "
                    + "Transfer this card again to re-verify it, then erase."
                )
            }

            let folder = relativeDestinationFolder(for: record, session: session)
            await progress?(OperationProgress(
                phase: .reVerifying,
                currentItem: item.fileName,
                completedFiles: verifiedFiles,
                totalFiles: currentMedia.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSourceURL: item.sourceURL,
                currentDestinationFolder: folder
            ))

            // Two full reads per file; the bar shows the pair as one 0...1 pass so a long video does
            // not look stuck.
            let counter = ProgressCounter()
            let base = OperationProgress(
                phase: .reVerifying,
                currentItem: item.fileName,
                completedFiles: verifiedFiles,
                totalFiles: currentMedia.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSourceURL: item.sourceURL,
                currentDestinationFolder: folder
            )
            let (sourceHash, destinationHash) = try await withPeriodicReports(
                of: base, counter: counter, total: item.size * 2, to: progress
            ) {
                (
                    try await FileHasher.sha256(at: item.sourceURL) { counter.value = $0 },
                    try await FileHasher.sha256(at: record.destinationURL) { counter.value = item.size + $0 }
                )
            }
            guard sourceHash.caseInsensitiveCompare(record.sha256) == .orderedSame,
                  destinationHash.caseInsensitiveCompare(record.sha256) == .orderedSame else {
                throw MediaShuttleError.eraseBlocked(
                    "\(item.fileName) no longer matches its verified copy. "
                    + "Transfer this card again to re-verify it, then erase."
                )
            }
            verifiedFiles += 1
            processedBytes += item.size
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        let protected = entries.filter(MediaClassifier.isSystemManagedRootEntry)
        let userEntries = entries.filter { !MediaClassifier.isSystemManagedRootEntry($0) }
        var deletedFiles = 0
        var failures: [String] = []

        for (index, entry) in userEntries.enumerated() {
            // Deletion has no byte total to measure against, so progress is counted in entries and
            // the byte figures are left at zero. Reporting the entry count as a byte count made the
            // processed and throughput readouts show "12 B of 12 B" at "0 B/s avg" during an erase.
            await progress?(OperationProgress(
                phase: .erasing,
                currentItem: entry.lastPathComponent,
                completedFiles: index,
                totalFiles: max(1, userEntries.count),
                processedBytes: 0,
                totalBytes: 0
            ))
            do {
                deletedFiles += try deleteEntry(entry, within: root)
            } catch {
                failures.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ))?.filter { !MediaClassifier.isSystemManagedRootEntry($0) } ?? []
        let remainingMedia = try MediaClassifier.scan(root)
        if !failures.isEmpty || !remaining.isEmpty || !remainingMedia.isEmpty {
            let details = (failures + remaining.map(\.lastPathComponent)).prefix(5).joined(separator: ", ")
            throw MediaShuttleError.eraseBlocked(
                "some card content could not be removed (\(details)). Check the card's write-protect switch and try again."
            )
        }

        var erasedSession = session
        erasedSession.status = "Erased"
        erasedSession.erasedAt = .now
        erasedSession.erasedFileCount = deletedFiles
        _ = try await stateStore.saveSession(erasedSession)
        await logger.write("Card erase complete: \(deletedFiles) files removed")
        await progress?(OperationProgress(
            phase: .complete,
            currentItem: "Card contents erased",
            completedFiles: max(1, userEntries.count),
            totalFiles: max(1, userEntries.count),
            processedBytes: 0,
            totalBytes: 0
        ))
        return WipeResult(
            deletedFiles: deletedFiles,
            protectedSystemEntries: protected.map(\.lastPathComponent)
        )
    }

    private func validate(card: CardInfo, session: TransferSession) throws {
        guard session.status.caseInsensitiveCompare("Verified") == .orderedSame else {
            throw MediaShuttleError.eraseLocked
        }
        guard session.sourceRoot.standardizedFileURL.path == card.rootURL.standardizedFileURL.path,
              session.sourceVolumeID == card.volumeID else {
            throw MediaShuttleError.cardChanged
        }
    }

    private func deleteEntry(_ url: URL, within root: URL) throws -> Int {
        try Task.checkCancellation()
        try ensureSafeChild(url, root: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true || values.isDirectory != true {
            try removeWithRetry(url)
            return 1
        }

        var count = 0
        for child in try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            try Task.checkCancellation()
            count += try deleteEntry(child, within: root)
        }
        try removeWithRetry(url)
        return count
    }

    private func removeWithRetry(_ url: URL) throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1 * Double(attempt))
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func ensureSafeChild(_ candidate: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard candidate.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw MediaShuttleError.unsafePath
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func relativeDestinationFolder(for record: TransferRecord, session: TransferSession) -> String {
        let root = session.destinationRoot.standardizedFileURL.path.hasSuffix("/")
            ? session.destinationRoot.standardizedFileURL.path
            : session.destinationRoot.standardizedFileURL.path + "/"
        let directory = record.destinationURL.deletingLastPathComponent().standardizedFileURL.path
        return directory.hasPrefix(root) ? String(directory.dropFirst(root.count)) : directory
    }
}
