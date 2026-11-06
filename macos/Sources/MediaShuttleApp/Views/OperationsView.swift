import MediaShuttleCore
import SwiftUI

struct OperationsView: View {
    @Bindable var model: AppModel
    let showEraseConfirmation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = model.banner {
                BannerView(message: banner, onDismiss: model.dismissBanner)
            }

            SessionPanel(model: model)

            if model.settings.showActivityLog {
                // Sized before the spacer below, so a tall window grows the log
                // rather than the gap above the erase bar.
                ActivityLog(entries: model.activities)
                    .layoutPriority(1)
            }

            Spacer(minLength: 4)

            EraseBar(model: model, showEraseConfirmation: showEraseConfirmation)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

// MARK: - Banner

private struct BannerView: View {
    let message: BannerMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if message.tone == .success {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Theme.contentBackground)
                        .frame(width: 14, height: 14)
                        .background(message.tone.color)
                } else {
                    Image(systemName: message.tone.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(message.tone.color)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message.message)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Dismiss")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(message.tone.color.opacity(0.07))
        .overlay(Rectangle().strokeBorder(message.tone.color.opacity(0.32), lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(message.tone.color)
                .frame(width: 3)
        }
    }
}

// MARK: - Session

private struct SessionPanel: View {
    @Bindable var model: AppModel

    private var phaseColor: Color {
        switch model.progress.phase {
        case .complete: Theme.verified
        case .error: Theme.accent
        case .cancelled: Theme.caution
        case .idle: Theme.textMuted
        default: Theme.textBright
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
                header
                SegmentedProgressBar(fraction: model.progress.fraction, color: phaseColor)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 8)
                Hairline()
                metrics
                Hairline()
                footer
            }
            .panelBox()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel("THIS SESSION")
            Spacer(minLength: 8)
            Text(model.progress.phase.label)
                .font(Theme.mono(9.5))
                .tracking(0.6)
                .foregroundStyle(phaseColor)
            Text(model.progress.fraction, format: .percent.precision(.fractionLength(0)))
                .font(Theme.mono(9.5, .semibold))
                .foregroundStyle(phaseColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            let processed = Self.split(bytes: model.progress.processedBytes)
            let total = ByteCountFormatter.shuttleString(model.progress.totalBytes)
            let rate = model.throughputBytesPerSecond.map { Self.split(bytes: Int64($0)) }

            // An erase is measured in entries deleted, not bytes moved, and reports no byte total.
            // Its own progress is in the phase, percentage and current entry above; the copy
            // figures do not apply to it.
            let inBytes = model.progress.totalBytes > 0

            Metric(
                label: "COPIED",
                value: inBytes ? model.progress.copiedFiles.formatted() : "—",
                caption: "files"
            )
            MetricDivider()
            Metric(
                label: "ALREADY SAFE",
                value: inBytes ? model.progress.skippedFiles.formatted() : "—",
                caption: "re-verified"
            )
            MetricDivider()
            Metric(
                label: "PROCESSED",
                value: inBytes ? processed.value : "—",
                caption: inBytes ? "\(processed.unit) of \(total)" : "not counted in bytes"
            )
            MetricDivider()
            Metric(
                label: "THROUGHPUT",
                value: rate?.value ?? "—",
                caption: rate.map { "\($0.unit)/s avg" } ?? "idle"
            )
            MetricDivider()
            Metric(label: "ELAPSED", value: Self.elapsed(model.elapsed), caption: "min:sec")
        }
        // Without this the 1px dividers, being vertically flexible, stretch the
        // whole panel to fill the window.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(currentActivity)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let photos = model.photosProgress {
                Button(photos.total > 0 ? "Stop Photos · \(photos.completed)/\(photos.total)" : "Opening Photos…",
                       action: model.cancelAddToPhotos)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                    .help("Stop adding to Apple Photos. Items already added stay in the library.")
            } else {
                Button("Add to Photos", action: model.addToPhotos)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                    .disabled(!model.canAddToPhotos)
                    .help("Add the verified copies to Apple Photos, which syncs them through iCloud Photos.")
            }

            Button("Report", action: model.openReport)
                .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                .disabled(model.reportURL == nil)

            if model.isBusy, model.progress.phase != .erasing, model.progress.phase != .reVerifying {
                Button("Cancel", action: model.cancelTransfer)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary))
            }

            // With no card the title reads "Scan for media", so run a scan
            // rather than a transfer.
            Button(model.isDestinationAvailable ? model.primaryActionTitle : "Choose destination") {
                if !model.isDestinationAvailable {
                    model.chooseDestination()
                } else if hasCard {
                    model.startTransfer()
                } else {
                    model.scanNow()
                }
            }
            .buttonStyle(ShuttleButtonStyle(kind: .primary))
            .disabled(model.isDestinationAvailable ? (hasCard ? !model.canTransfer : model.isBusy) : model.isBusy)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Theme.panelFooterBackground)
    }

    private var hasCard: Bool { model.currentCard != nil }

    private var currentActivity: String {
        if model.progress.phase == .idle, model.currentCard != nil {
            return model.media.isEmpty ? "No supported media found" : "Ready to transfer and verify"
        }
        guard let source = model.progress.currentSourceURL else { return model.progress.currentItem }
        let folder = model.progress.currentDestinationFolder
        return folder.isEmpty ? source.path : "LAST · \(source.path) → \(folder)"
    }

    private static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Splits "10.1 GB" into its number and unit so the metric can show the
    /// value large with the unit as a caption, as the design does.
    private static func split(bytes: Int64) -> (value: String, unit: String) {
        let formatted = ByteCountFormatter.shuttleString(bytes)
        let parts = formatted.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (formatted, "") }
        return (String(parts[0]), String(parts[1]))
    }
}

private struct SegmentedProgressBar: View {
    let fraction: Double
    let color: Color

    private static let segments = 32

    var body: some View {
        let filled = Int((fraction * Double(Self.segments)).rounded())
        HStack(spacing: 1) {
            ForEach(0..<Self.segments, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? color : Theme.hairlineSoft)
                    .frame(height: 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: filled)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

private struct Metric: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value)
                .font(Theme.mono(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(caption)")
    }
}

private struct MetricDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
    }
}

// MARK: - Activity

private struct ActivityLog: View {
    let entries: [ActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SectionLabel("ACTIVITY")
                Hairline()
            }

            ScrollView {
                // Every entry the model keeps: the list scrolls, and truncating it at 20 threw
                // away the older half of a log the model had already decided to hold on to.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(Theme.textMuted)
                            Text(entry.message)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(Theme.mono(10))
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) { Hairline(color: Theme.hairlineSoft) }
                    }
                }
            }
            // The upper bound stops the log swallowing a full-screen window; past
            // that the spare height falls to the spacer above the erase bar.
            .frame(minHeight: 108, maxHeight: 460)
        }
    }
}

// MARK: - Erase

private struct EraseBar: View {
    @Bindable var model: AppModel
    let showEraseConfirmation: () -> Void

    private var detail: String {
        if !model.sourceAllowsErase {
            return "Erase is available only for camera-card volumes. Selected folders support transfer and verification."
        }
        if model.canWipe {
            let root = model.currentCard?.rootURL.path ?? "the card"
            return "Every remaining file on \(root) has a verified copy · typed confirmation required"
        }
        switch model.unverifiableFileCount {
        case 0: break
        case 1:
            return "Locked — one file on this card is not recognised camera media, "
                + "so no transfer can verify it. Copy it off the card yourself."
        default:
            return "Locked — \(model.unverifiableFileCount) files on this card are not recognised "
                + "camera media, so no transfer can verify them. Copy them off the card yourself."
        }
        if model.media.isEmpty, model.currentCard != nil {
            return "No verified media is available to erase."
        }
        return "Locked until every remaining camera file has a verified destination copy."
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Erase card")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.canWipe ? "UNLOCKED" : "LOCKED")
                        .font(Theme.mono(9))
                        .tracking(1)
                        .foregroundStyle(model.canWipe ? Theme.accent : Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .overlay(
                            Rectangle().strokeBorder(
                                model.canWipe ? Theme.accent.opacity(0.45) : Theme.hairline,
                                lineWidth: 1
                            )
                        )
                }
                Text(detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Erase everything on card", action: showEraseConfirmation)
                .buttonStyle(ShuttleButtonStyle(kind: .destructive))
                .disabled(!model.canWipe)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .panelBox()
    }
}
