import Foundation
import MediaShuttleCore
import Photos

/// Adds verified destination copies to the system Photos library, from which iCloud Photos syncs
/// them to every device on the account. Only add-only access is requested: the app writes new
/// assets and never reads, changes or deletes anything already in the library.
enum PhotosImporter {
    struct Failure: Sendable {
        let name: String
        let reason: String
    }

    struct Outcome: Sendable {
        var addedItems = 0
        var addedFiles = 0
        var importedHashes: [String] = []
        var failures: [Failure] = []
    }

    enum AccessError: LocalizedError {
        case denied
        case restricted
        case unbundled

        var errorDescription: String? {
            switch self {
            case .denied:
                "Media Shuttle is not allowed to add to Photos. Turn it on in System Settings › "
                    + "Privacy & Security › Photos, then try again."
            case .restricted:
                "Adding to Photos is restricted on this Mac, for example by a device management profile."
            case .unbundled:
                "Adding to Photos needs the packaged Media Shuttle.app. A `swift run` build has no "
                    + "bundle for macOS to grant Photos access to."
            }
        }
    }

    /// Small enough that one asset Photos refuses only costs a short retry of its neighbours, large
    /// enough that a few hundred photos are not a few hundred separate library transactions.
    private static let batchSize = 24

    static func requestAccess() async throws {
        // Without a bundle there is no usage description, and TCC terminates a process that asks
        // for a protected resource without one.
        guard Bundle.isPackagedApp else { throw AccessError.unbundled }
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: return
        case .restricted: throw AccessError.restricted
        default: throw AccessError.denied
        }
    }

    static func add(
        _ items: [PhotosImportItem],
        progress: @escaping @MainActor (_ completed: Int, _ importedHashes: [String]) async -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        var completed = 0
        var start = 0
        while start < items.count {
            if Task.isCancelled { break }
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            start += batch.count
            let hashesBefore = outcome.importedHashes.count
            do {
                try await perform(batch)
                record(batch, into: &outcome)
            } catch {
                // A change block is all-or-nothing, so one unreadable file fails its whole batch.
                // Retry one at a time to keep the others and name the one Photos refused.
                for item in batch {
                    do {
                        try await perform([item])
                        record([item], into: &outcome)
                    } catch {
                        outcome.failures.append(Failure(name: item.displayName, reason: error.localizedDescription))
                    }
                }
            }
            completed += batch.count
            // Reported per batch so the caller can record what Photos now holds as it goes: an
            // import interrupted by quitting must not add the same files again next time.
            await progress(completed, Array(outcome.importedHashes[hashesBefore...]))
        }
        return outcome
    }

    private static func record(_ batch: [PhotosImportItem], into outcome: inout Outcome) {
        outcome.addedItems += batch.count
        outcome.addedFiles += batch.reduce(0) { $0 + ($1.pairedRawURL == nil ? 1 : 2) }
        outcome.importedHashes += batch.flatMap(\.hashes)
    }

    private static func perform(_ batch: [PhotosImportItem]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for item in batch {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Photos copies the file into its library. The verified copy at the destination stays.
                options.shouldMoveFile = false
                options.originalFilename = item.primaryURL.lastPathComponent
                switch item.kind {
                case .video:
                    request.addResource(with: .video, fileURL: item.primaryURL, options: options)
                case .photo:
                    request.addResource(with: .photo, fileURL: item.primaryURL, options: options)
                    if let raw = item.pairedRawURL {
                        let rawOptions = PHAssetResourceCreationOptions()
                        rawOptions.shouldMoveFile = false
                        rawOptions.originalFilename = raw.lastPathComponent
                        request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
                    }
                }
            }
        }
    }
}
