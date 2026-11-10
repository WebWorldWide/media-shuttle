import CryptoKit
import Foundation

public actor TransferService {
    public typealias ProgressHandler = @Sendable (OperationProgress) async -> Void

    private static let bufferSize = 1_048_576
    private static let partialMarker = ".partial-"
    private static let reportInterval: Duration = .milliseconds(50)

    private let stateStore: StateStore
    private let logger: AppLogger

    public init(stateStore: StateStore, logger: AppLogger) {
        self.stateStore = stateStore
        self.logger = logger
    }

    public func transfer(
        card: CardInfo,
        destinationRoot: URL,
        groupByDate: Bool,
        progress: ProgressHandler? = nil
    ) async throws -> TransferResult {
        let destinationRoot = destinationRoot.standardizedFileURL
        try ensureDestinationOutsideCard(destinationRoot, cardRoot: card.rootURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        try ensureDestinationOutsideCard(
            destinationRoot.resolvingSymlinksInPath(),
            cardRoot: card.rootURL.resolvingSymlinksInPath()
        )
        await progress?(OperationProgress(
            phase: .scanning,
            currentItem: "Scanning card",
            completedFiles: 0,
            totalFiles: 0,
            processedBytes: 0,
            totalBytes: 0
        ))
        await cleanupPartials(at: destinationRoot)
        await logger.write("Scanning \(card.rootURL.path) for camera media")
        let media = try MediaClassifier.scan(card.rootURL)
        guard !media.isEmpty else { throw MediaShuttleError.noSupportedMedia }

        let totalBytes = media.reduce(Int64(0)) { $0 + $1.size }
        try ensureFreeSpace(
            at: destinationRoot,
            requiredBytes: estimatedBytesToWrite(for: media, destinationRoot: destinationRoot, groupByDate: groupByDate)
        )
        try ensureDestinationFolders(for: media, at: destinationRoot)
        var session = TransferSession(
            card: card,
            destinationRoot: destinationRoot,
            totalFiles: media.count,
            totalBytes: totalBytes
        )

        var processedBytes: Int64 = 0
        var completedFiles = 0

        for item in media {
            try Task.checkCancellation()
            var folder = MediaClassifier.destinationFolder(for: item.kind, under: destinationRoot)
            if groupByDate {
                folder.appendPathComponent(Self.dateFolder(for: item.modifiedAt), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try ensureDestinationFolder(folder, under: destinationRoot, outside: card.rootURL)

            let relativeFolder = relativePath(of: folder, under: destinationRoot)
            var destinationURL = folder.appendingPathComponent(item.fileName)
            var sourceHash: String?
            var skipped = false

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let existingSize = Self.fileSize(at: destinationURL)
                if existingSize == item.size {
                    await progress?(OperationProgress(
                        phase: .checkingDuplicate,
                        currentItem: item.fileName,
                        completedFiles: completedFiles,
                        totalFiles: media.count,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        copiedFiles: session.copiedCount,
                        skippedFiles: session.skippedCount,
                        currentSourceURL: item.sourceURL,
                        currentDestinationFolder: relativeFolder
                    ))
                    // Two full reads for a file that is probably already safe. On a 50 GB video that
                    // is minutes with the bar still, so report the pair as one 0...1 pass.
                    let counter = ProgressCounter()
                    let base = OperationProgress(
                        phase: .checkingDuplicate,
                        currentItem: item.fileName,
                        completedFiles: completedFiles,
                        totalFiles: media.count,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        copiedFiles: session.copiedCount,
                        skippedFiles: session.skippedCount,
                        currentSourceURL: item.sourceURL,
                        currentDestinationFolder: relativeFolder
                    )
                    let (calculatedSourceHash, existingHash) = try await withPeriodicReports(
                        of: base, counter: counter, total: item.size * 2, to: progress
                    ) {
                        (
                            try await FileHasher.sha256(at: item.sourceURL) { counter.value = $0 },
                            try await FileHasher.sha256(at: destinationURL) { counter.value = item.size + $0 }
                        )
                    }
                    sourceHash = calculatedSourceHash
                    if calculatedSourceHash.caseInsensitiveCompare(existingHash) == .orderedSame {
                        skipped = true
                        session.skippedCount += 1
                        await logger.write("Verified existing \(item.fileName)")
                    }
                }
                if !skipped {
                    // A name collision from an earlier run was kept as "NAME (2).EXT". Look for this
                    // file among those before picking a new name: otherwise every repeat transfer of
                    // the card wrote yet another copy, (3), (4) and on, of a file already safe.
                    let hashForSearch: String
                    if let sourceHash {
                        hashForSearch = sourceHash
                    } else if hasNumberedVariant(in: folder, fileName: item.fileName, size: item.size) {
                        hashForSearch = try await FileHasher.sha256(at: item.sourceURL)
                        sourceHash = hashForSearch
                    } else {
                        hashForSearch = ""
                    }
                    if !hashForSearch.isEmpty, let existing = try await existingNumberedCopy(
                        in: folder,
                        fileName: item.fileName,
                        size: item.size,
                        sha256: hashForSearch
                    ) {
                        destinationURL = existing
                        skipped = true
                        session.skippedCount += 1
                        await logger.write("Verified existing \(existing.lastPathComponent)")
                    } else {
                        destinationURL = uniqueURL(in: folder, fileName: item.fileName)
                    }
                }
            }

            let verifiedHash: String
            if skipped {
                if let sourceHash {
                    verifiedHash = sourceHash
                } else {
                    verifiedHash = try await FileHasher.sha256(at: item.sourceURL)
                }
                processedBytes += item.size
            } else {
                let copyResult = try await copyAndVerify(
                    item: item,
                    destinationURL: destinationURL,
                    completedFiles: completedFiles,
                    totalFiles: media.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    copiedFiles: session.copiedCount,
                    skippedFiles: session.skippedCount,
                    destinationFolder: relativeFolder,
                    progress: progress
                )
                processedBytes = copyResult.processedBytes
                verifiedHash = copyResult.hash
                session.copiedCount += 1
            }

            completedFiles += 1
            session.files.append(TransferRecord(
                sourceURL: item.sourceURL,
                destinationURL: destinationURL,
                sha256: verifiedHash,
                size: item.size,
                kind: item.kind
            ))
            await progress?(OperationProgress(
                phase: .verifying,
                currentItem: item.fileName,
                completedFiles: completedFiles,
                totalFiles: media.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                copiedFiles: session.copiedCount,
                skippedFiles: session.skippedCount,
                currentSourceURL: item.sourceURL,
                currentDestinationFolder: relativeFolder
            ))
        }

        session.completedAt = .now
        session.status = "Verified"
        let reportURL = try await stateStore.saveSession(session)
        await logger.write(
            "Transfer verified: \(session.copiedCount) copied, \(session.skippedCount) already safe"
        )
        await progress?(OperationProgress(
            phase: .complete,
            currentItem: "Transfer verified",
            completedFiles: media.count,
            totalFiles: media.count,
            processedBytes: totalBytes,
            totalBytes: totalBytes,
            copiedFiles: session.copiedCount,
            skippedFiles: session.skippedCount
        ))
        return TransferResult(session: session, sessionFileURL: reportURL)
    }

    private func copyAndVerify(
        item: MediaItem,
        destinationURL: URL,
        completedFiles: Int,
        totalFiles: Int,
        processedBytes: Int64,
        totalBytes: Int64,
        copiedFiles: Int,
        skippedFiles: Int,
        destinationFolder: String,
        progress: ProgressHandler?
    ) async throws -> (hash: String, processedBytes: Int64) {
        let temporaryURL = URL(fileURLWithPath: destinationURL.path + Self.partialMarker + Self.compactUUID())
        var currentBytes = processedBytes
        var copiedBytes: Int64 = 0

        // A fast reader hands over a megabyte many hundreds of times a second. Each report is a hop
        // to the main actor, so mid-file reports are spaced out here; every change of phase still
        // goes through at once.
        let throttle = ProgressThrottle(interval: Self.reportInterval)
        func snapshot(_ phase: OperationPhase, processed: Int64, itemFraction: Double) -> OperationProgress {
            OperationProgress(
                phase: phase,
                currentItem: item.fileName,
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                processedBytes: processed,
                totalBytes: totalBytes,
                copiedFiles: copiedFiles,
                skippedFiles: skippedFiles,
                currentSourceURL: item.sourceURL,
                currentDestinationFolder: destinationFolder,
                currentItemFraction: itemFraction
            )
        }

        do {
            await logger.write("Copying \(item.fileName)")
            if throttle.allows(force: true) {
                await progress?(snapshot(.copying, processed: currentBytes, itemFraction: 0))
            }
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw MediaShuttleError.writeFailed(
                    file: item.fileName,
                    reason: "A new file couldn't be created in \(destinationFolder). "
                        + "Check that the destination drive is connected and not full or read-only."
                )
            }
            let source: FileHandle
            do {
                source = try FileHandle(forReadingFrom: item.sourceURL)
            } catch {
                throw MediaShuttleError.readFailed(file: item.fileName, reason: MediaShuttleError.plainReason(for: error))
            }
            let destination: FileHandle
            do {
                destination = try FileHandle(forWritingTo: temporaryURL)
            } catch {
                try? source.close()
                throw MediaShuttleError.writeFailed(file: item.fileName, reason: MediaShuttleError.plainReason(for: error))
            }
            defer {
                try? source.close()
                try? destination.close()
            }

            var sourceHasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data: Data
                do {
                    data = try source.read(upToCount: Self.bufferSize) ?? Data()
                } catch {
                    throw MediaShuttleError.readFailed(file: item.fileName, reason: MediaShuttleError.plainReason(for: error))
                }
                if data.isEmpty { break }
                sourceHasher.update(data: data)
                do {
                    try destination.write(contentsOf: data)
                } catch {
                    throw MediaShuttleError.writeFailed(file: item.fileName, reason: MediaShuttleError.plainReason(for: error))
                }
                currentBytes += Int64(data.count)
                copiedBytes += Int64(data.count)
                if throttle.allows(force: false) {
                    await progress?(snapshot(
                        .copying, processed: currentBytes, itemFraction: Double(copiedBytes) / Double(max(item.size, 1))
                    ))
                }
            }
            guard copiedBytes == item.size else {
                throw MediaShuttleError.sourceChanged(item.fileName)
            }
            do {
                // Flushing gigabytes of buffered writes to a slow drive can take a while on its own;
                // the bar is shown full for this file so the wait reads as the end of the copy.
                if throttle.allows(force: true) {
                    await progress?(snapshot(.copying, processed: currentBytes, itemFraction: 1))
                }
                try destination.synchronize()
            } catch {
                throw MediaShuttleError.writeFailed(file: item.fileName, reason: MediaShuttleError.plainReason(for: error))
            }
            try FileManager.default.setAttributes(
                [.modificationDate: item.modifiedAt],
                ofItemAtPath: temporaryURL.path
            )

            if throttle.allows(force: true) {
                await progress?(snapshot(.verifying, processed: currentBytes, itemFraction: 0))
            }
            let sourceHash = sourceHasher.finalize().map { String(format: "%02X", $0) }.joined()

            // The read-back of a large file is the longest silent stretch in a transfer, so it is
            // reported a few times a second while the hash runs.
            let verifiedBytes = ProgressCounter()
            let destinationHash: String
            do {
                destinationHash = try await withPeriodicReports(
                    of: snapshot(.verifying, processed: currentBytes, itemFraction: 0),
                    counter: verifiedBytes, total: item.size, to: progress
                ) {
                    try await FileHasher.sha256(at: temporaryURL) { verifiedBytes.value = $0 }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MediaShuttleError.writeFailed(
                    file: item.fileName,
                    reason: "The copy couldn't be read back to check it. " + MediaShuttleError.plainReason(for: error)
                )
            }
            guard sourceHash.caseInsensitiveCompare(destinationHash) == .orderedSame else {
                throw MediaShuttleError.verificationFailed(item.fileName)
            }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            } catch {
                throw MediaShuttleError.writeFailed(
                    file: item.fileName,
                    reason: "The verified copy couldn't be renamed into place. " + MediaShuttleError.plainReason(for: error)
                )
            }
            await logger.write("Verified \(item.fileName)")
            return (sourceHash, currentBytes)
        } catch {
            do {
                try FileManager.default.removeItem(at: temporaryURL)
            } catch let removeError {
                await logger.write(
                    "Could not remove unfinished copy \(temporaryURL.lastPathComponent): "
                        + MediaShuttleError.plainReason(for: removeError)
                )
            }
            throw error
        }
    }

    private func ensureDestinationOutsideCard(_ destination: URL, cardRoot: URL) throws {
        let cardPath = cardRoot.standardizedFileURL.path
        let cardPrefix = cardPath.hasSuffix("/") ? cardPath : cardPath + "/"
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath != cardPath, !destinationPath.hasPrefix(cardPrefix) else {
            throw MediaShuttleError.unsafePath
        }
    }

    private func ensureDestinationFolder(_ folder: URL, under root: URL, outside cardRoot: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFolder == resolvedRoot || resolvedFolder.hasPrefix(rootPrefix) else {
            throw MediaShuttleError.unsafePath
        }
        try ensureDestinationOutsideCard(
            folder.resolvingSymlinksInPath(),
            cardRoot: cardRoot.resolvingSymlinksInPath()
        )
    }

    /// Creates a category folder only for the kinds this card actually holds. Creating all four up
    /// front left an empty Photos/Other next to every transfer of a card with no other-format
    /// photos, which reads as a category that failed rather than one that was never needed.
    private func ensureDestinationFolders(for media: [MediaItem], at root: URL) throws {
        for kind in Set(media.map(\.kind)) {
            try FileManager.default.createDirectory(
                at: MediaClassifier.destinationFolder(for: kind, under: root),
                withIntermediateDirectories: true
            )
        }
    }

    /// Removes unfinished copies left by an earlier run. Only the folders this app writes to are
    /// searched: walking the whole destination stalled for minutes, before the first progress
    /// report, whenever the destination was the root of a large drive. A copy that cannot be
    /// removed is logged, since a 50 GB leftover is worth knowing about.
    private func cleanupPartials(at root: URL) async {
        var removed = 0
        for kind in MediaKind.allCases {
            let folder = MediaClassifier.destinationFolder(for: kind, under: root)
            guard FileManager.default.fileExists(atPath: folder.path),
                  let enumerator = FileManager.default.enumerator(
                      at: folder,
                      includingPropertiesForKeys: [.isRegularFileKey],
                      options: [.skipsPackageDescendants],
                      errorHandler: { _, _ in true }
                  ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard isOwnedPartial(url.lastPathComponent) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {
                    await logger.write(
                        "Could not remove unfinished copy \(url.lastPathComponent): "
                            + MediaShuttleError.plainReason(for: error)
                    )
                }
            }
        }
        if removed > 0 {
            await logger.write("Removed \(removed) unfinished \(removed == 1 ? "copy" : "copies") left by an earlier transfer")
        }
    }

    private func isOwnedPartial(_ fileName: String) -> Bool {
        guard let range = fileName.range(of: Self.partialMarker, options: .backwards) else { return false }
        let identifier = fileName[range.upperBound...]
        return identifier.count == 32 && identifier.allSatisfy(\.isHexDigit)
    }

    private func uniqueURL(in directory: URL, fileName: String) -> URL {
        var number = 2
        while true {
            let candidate = numberedURL(in: directory, fileName: fileName, number: number)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private func numberedURL(in directory: URL, fileName: String, number: Int) -> URL {
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        return directory.appendingPathComponent("\(stem) (\(number))\(suffix)")
    }

    /// Cheap pre-check so a card with no earlier collisions never pays for an extra source hash.
    private func hasNumberedVariant(in directory: URL, fileName: String, size: Int64) -> Bool {
        var number = 2
        while true {
            let candidate = numberedURL(in: directory, fileName: fileName, number: number)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
            if Self.fileSize(at: candidate) == size { return true }
            number += 1
        }
    }

    private func existingNumberedCopy(
        in directory: URL,
        fileName: String,
        size: Int64,
        sha256: String
    ) async throws -> URL? {
        var number = 2
        while true {
            let candidate = numberedURL(in: directory, fileName: fileName, number: number)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            if Self.fileSize(at: candidate) == size {
                let candidateHash = try await FileHasher.sha256(at: candidate)
                if candidateHash.caseInsensitiveCompare(sha256) == .orderedSame { return candidate }
            }
            number += 1
        }
    }

    /// Bytes this transfer may actually have to write. A file already present under its own name at
    /// the same size is almost always the copy a previous run made and is skipped after hashing, so
    /// counting it made "Transfer again" on a full card demand the card's whole size in free space a
    /// second time and fail with nothing left to copy. A same-size file that turns out to differ is
    /// written under a new name; the reserve covers that, and the copy itself fails cleanly if not.
    private func estimatedBytesToWrite(
        for media: [MediaItem],
        destinationRoot: URL,
        groupByDate: Bool
    ) -> Int64 {
        media.reduce(Int64(0)) { total, item in
            var folder = MediaClassifier.destinationFolder(for: item.kind, under: destinationRoot)
            if groupByDate {
                folder.appendPathComponent(Self.dateFolder(for: item.modifiedAt), isDirectory: true)
            }
            let existing = folder.appendingPathComponent(item.fileName)
            return Self.fileSize(at: existing) == item.size ? total : total + item.size
        }
    }

    /// The "important usage" figure counts purgeable space on APFS, which is the honest number for
    /// the startup disk. On exFAT and other non-APFS volumes, the format most camera-destination
    /// drives use, it reports zero, so every transfer to such a drive was refused as "not enough
    /// free space" with a terabyte free. Fall back to the plain figure there.
    private func ensureFreeSpace(at destination: URL, requiredBytes: Int64) throws {
        let values = try destination.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let available = important > 0 ? important : plain
        guard available > 0 else { return }
        let reserve: Int64 = 1_073_741_824
        guard available >= requiredBytes + reserve else { throw MediaShuttleError.insufficientSpace }
    }

    private func relativePath(of child: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard child.standardizedFileURL.path.hasPrefix(rootPath) else { return child.lastPathComponent }
        return String(child.standardizedFileURL.path.dropFirst(rootPath.count))
    }

    private static func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func dateFolder(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }
}
