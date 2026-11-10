import Foundation

/// A byte count written from a hashing loop and read by a progress reporter on another task.
public final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    public init() {}

    public var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Spaces out mid-file progress reports. Used from one actor method at a time.
final class ProgressThrottle {
    private let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    func allows(force: Bool) -> Bool {
        let now = ContinuousClock.now
        if !force, let last, now - last < interval { return false }
        last = now
        return true
    }
}

/// Runs `work`, a long read of one file, while a side task sends `base` with the current fraction of
/// `total` a few times a second. Reading back a 50 GB video is minutes during which nothing else
/// changes; without these reports the bar sat still and the transfer looked hung.
func withPeriodicReports<T: Sendable>(
    of base: OperationProgress,
    counter: ProgressCounter,
    total: Int64,
    to progress: (@Sendable (OperationProgress) async -> Void)?,
    work: () async throws -> T
) async throws -> T {
    guard let progress else { return try await work() }
    let size = Double(max(total, 1))
    let reporter = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await progress(base.withItemFraction(Double(counter.value) / size))
        }
    }
    defer { reporter.cancel() }
    return try await work()
}

extension OperationProgress {
    func withItemFraction(_ fraction: Double) -> OperationProgress {
        OperationProgress(
            phase: phase,
            currentItem: currentItem,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            copiedFiles: copiedFiles,
            skippedFiles: skippedFiles,
            currentSourceURL: currentSourceURL,
            currentDestinationFolder: currentDestinationFolder,
            currentItemFraction: fraction
        )
    }
}
