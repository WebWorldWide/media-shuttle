import Foundation

public enum CardDetector {
    private static let cameraFolders = ["DCIM", "M4ROOT", "PRIVATE"]

    public static func selectedSource(at url: URL) throws -> CardInfo {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .volumeURLKey, .volumeNameKey, .volumeUUIDStringKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]
        let values = try root.resourceValues(forKeys: keys)
        guard root.path != "/", values.isDirectory == true else {
            throw MediaShuttleError.unsafePath
        }
        let isVolumeRoot = values.volume?.standardizedFileURL.resolvingSymlinksInPath() == root
        return CardInfo(
            rootURL: root,
            volumeLabel: isVolumeRoot ? (values.volumeName ?? root.lastPathComponent) : root.lastPathComponent,
            volumeID: values.volumeUUIDString ?? root.path,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            driveType: isVolumeRoot ? "Selected volume" : "Selected folder"
        )
    }

    /// A folder can be used for ingest without granting the app a way to erase arbitrary folders
    /// on the Mac. Manual erase is restricted to external camera volumes, selected at their root.
    public static func isCameraCardVolume(_ url: URL) -> Bool {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? root.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey]),
              root.path != "/", values.volumeIsInternal == false,
              values.volume?.standardizedFileURL.resolvingSymlinksInPath() == root else {
            return false
        }
        return cameraFolders.contains {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent($0).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }

    /// True for the root of a mounted volume macOS can eject: a card or other external disk, never
    /// the startup disk or a folder inside a volume.
    public static func isEjectableVolumeRoot(_ url: URL) -> Bool {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != "/",
              let values = try? root.resourceValues(forKeys: [
                  .volumeURLKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey
              ]),
              values.volume?.standardizedFileURL.resolvingSymlinksInPath() == root else {
            return false
        }
        return values.volumeIsEjectable == true || values.volumeIsRemovable == true
            || values.volumeIsInternal == false
    }

    public static func candidates(destinationRoot: URL) -> [CardInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { volume in
            let root = volume.standardizedFileURL
            guard root.path != "/", !contains(destinationRoot.standardizedFileURL, in: root) else { return nil }
            guard cameraFolders.contains(where: {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0, isDirectory: true).path)
            }) else { return nil }

            guard let values = try? root.resourceValues(forKeys: Set(keys)) else { return nil }
            let identifier = values.volumeUUIDString ?? root.path
            let label = values.volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? "CAMERA MEDIA"
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            let type: String
            if values.volumeIsRemovable == true {
                type = "Removable media"
            } else if values.volumeIsInternal == true {
                type = "Mounted volume"
            } else {
                type = "External media"
            }
            return CardInfo(
                rootURL: root,
                volumeLabel: label,
                volumeID: identifier,
                totalBytes: total,
                freeBytes: free,
                driveType: type
            )
        }
        .sorted { $0.volumeLabel.localizedCaseInsensitiveCompare($1.volumeLabel) == .orderedAscending }
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(parentPath)
    }
}

public struct CardPresenceTracker: Sendable {
    private var seenRoots: Set<String> = []
    private var baselineEstablished = false

    public init() {}

    public mutating func observe(selectedRoot: URL?, activeRoots: [URL]) -> Bool {
        let active = Set(activeRoots.map { $0.standardizedFileURL.path })
        seenRoots.formIntersection(active)

        // Everything mounted at the first scan is the baseline: cards already in the reader when
        // the app launched are not arrivals, and must not start an automatic transfer.
        guard baselineEstablished else {
            seenRoots.formUnion(active)
            baselineEstablished = true
            return false
        }

        // Only the selected card is marked seen. Marking every mounted volume seen on every scan
        // meant a card inserted next to one already connected was recorded as seen while another
        // card held the selection, so it was never announced — no activity entry and, with
        // automatic transfer on, no transfer — even once the first card was removed.
        guard let selectedRoot else { return false }
        return seenRoots.insert(selectedRoot.standardizedFileURL.path).inserted
    }
}
