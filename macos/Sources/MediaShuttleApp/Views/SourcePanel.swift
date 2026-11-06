import MediaShuttleCore
import SwiftUI

struct SourcePanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SOURCE")
            sourceSummary
                .padding(.top, 14)
            Button("Open card folder…", action: model.chooseSource)
                .buttonStyle(ShuttleButtonStyle(kind: .primary, fullWidth: true))
                .disabled(model.isBusy)
                .accessibilityLabel("Open camera card folder")
                .padding(.top, 16)
            HStack(spacing: 5) {
                if model.selectedSourceURL != nil {
                    Button("Use auto-detect", action: model.useAutomaticSource)
                        .buttonStyle(ShuttleButtonStyle(kind: .secondary, fullWidth: true))
                        .disabled(model.isBusy)
                }
                if model.currentCardIsEjectable {
                    Button("Eject", action: model.ejectCard)
                        .buttonStyle(ShuttleButtonStyle(kind: .secondary, fullWidth: true))
                        .disabled(!model.canEject)
                        .help("Unmount and eject the card so it is safe to remove")
                }
            }
            .padding(.top, model.selectedSourceURL != nil || model.currentCardIsEjectable ? 8 : 0)

            Hairline().padding(.vertical, 16)

            SectionLabel("SOURCE CONTENTS")
            MediaBreakdown(counts: model.mediaCounts)
                .padding(.top, 12)

            Hairline().padding(.vertical, 16)

            SectionLabel("DESTINATION")
            destination
                .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source media summary")
    }

    private var assetCount: Int {
        model.mediaCounts.values.reduce(0, +)
    }

    private var destinationDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = model.destinationURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var sourceSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            MediaCardIcon(connected: model.currentCard != nil)
                .frame(width: 48, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentCard?.volumeLabel ?? model.selectedSourceURL?.lastPathComponent ?? "No source")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let card = model.currentCard {
                    Text("\(card.rootURL.path) · \(card.driveType)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                    Text("\(assetCount.formatted()) \(assetCount == 1 ? "asset" : "assets") · \(ByteCountFormatter.shuttleString(model.totalMediaBytes))")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textMuted)
                } else {
                    Text(model.selectedSourceURL == nil
                         ? "Choose a source or insert a camera card."
                         : "Selected source is unavailable.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(destinationDisplayPath)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textBright)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Destination folder")

            if !model.isDestinationAvailable {
                Text("Destination folder is missing or unavailable. Choose an existing folder to transfer.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Destination unavailable")
            }

            HStack(spacing: 5) {
                Button(model.isDestinationAvailable ? "Change" : "Choose folder", action: model.chooseDestination)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(model.isBusy)
                Button("Open", action: model.openDestination)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(!model.isDestinationAvailable)
            }

            Text("Photos/JPEGs\nPhotos/RAWs\nPhotos/Other\nVideos")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineSpacing(2)
        }
    }
}

/// Flat SD-card silhouette with the clipped top-right corner from the mock.
private struct MediaCardIcon: View {
    let connected: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let notch = w * 0.28

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: w - notch, y: 0))
                    path.addLine(to: CGPoint(x: w, y: notch))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(Theme.fillStrong)
                .overlay {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: w - notch, y: 0))
                        path.addLine(to: CGPoint(x: w, y: notch))
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.addLine(to: CGPoint(x: 0, y: h))
                        path.closeSubpath()
                    }
                    .stroke(Theme.hairline, lineWidth: 1)
                }

                Rectangle()
                    .fill(connected ? Theme.accent : Theme.textMuted.opacity(0.6))
                    .frame(width: 3, height: h * 0.4)
                    .offset(x: w * 0.13, y: h * 0.14)

                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(Theme.textMuted.opacity(0.55))
                            .frame(width: 2.5, height: h * 0.14)
                    }
                }
                .offset(x: w * 0.17, y: h * 0.72)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MediaBreakdown: View {
    let counts: [MediaKind: Int]

    private var itemCount: Int {
        counts.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    if itemCount == 0 {
                        Rectangle().fill(Theme.hairlineSoft)
                    } else {
                        ForEach(MediaKind.allCases, id: \.self) { kind in
                            let share = Double(counts[kind, default: 0]) / Double(itemCount)
                            if share > 0 {
                                Rectangle()
                                    .fill(kind.swatch)
                                    .frame(width: max(2, proxy.size.width * share))
                            }
                        }
                    }
                }
            }
            .frame(height: 6)

            VStack(spacing: 0) {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(kind.swatch)
                            .frame(width: 7, height: 7)
                        Text(kind.label)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 4)
                        Text(counts[kind, default: 0].formatted())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .font(Theme.mono(10))
                    .padding(.vertical, 2.5)
                }
            }
        }
    }
}

extension MediaKind {
    /// Monochrome ramp, lightest to darkest, as in the design document.
    fileprivate var swatch: Color {
        switch self {
        case .jpeg: Theme.textBright
        case .raw: Theme.textMuted
        case .otherPhoto: Theme.textMuted.opacity(0.62)
        case .video: Theme.textMuted.opacity(0.4)
        }
    }
}
