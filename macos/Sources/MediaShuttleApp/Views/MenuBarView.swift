import AppKit
import MediaShuttleCore
import SwiftUI

/// The status item. While something is running it carries the progress, so a transfer started
/// from the menu bar can be followed without opening anything.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            AppMark.menuBarGlyph
            if let text = progressText {
                Text(text)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel("Media Shuttle: \(model.topStatus)")
    }

    private var progressText: String? {
        if model.isBusy, model.progress.totalFiles > 0 || model.progress.totalBytes > 0 {
            return "\(Int((model.progress.fraction * 100).rounded()))%"
        }
        if let photos = model.photosProgress, photos.total > 0 {
            return "\(photos.completed)/\(photos.total)"
        }
        return nil
    }
}

/// The menu bar panel: everything a card ingest needs without the main window — what is
/// connected, live progress, the actions, the two automation switches, and recent activity.
/// Erase still opens the main window, because its typed confirmation belongs there.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            source
                .padding(12)
            if model.isBusy {
                Hairline()
                operationProgress
                    .padding(12)
            }
            if let photos = model.photosProgress {
                Hairline()
                photosProgress(photos)
                    .padding(12)
            }
            if let banner = model.banner {
                Hairline()
                bannerRow(banner)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            Hairline()
            actions
                .padding(.vertical, 5)
            Hairline()
            switches
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            if !model.activities.isEmpty {
                Hairline()
                recentActivity
                    .padding(12)
            }
            Hairline()
            footer
        }
        .frame(width: 340)
        .background(Theme.contentBackground)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 18)
            Text("MEDIA SHUTTLE")
                .font(Theme.mono(10, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Rectangle()
                    .fill(model.statusTone.color)
                    .frame(width: 5, height: 5)
                Text(model.topStatus)
                    .font(Theme.mono(9))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.fill)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.chromeBackground)
    }

    private var source: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.currentCard == nil ? "sdcard" : "sdcard.fill")
                .font(.system(size: 20))
                .foregroundStyle(model.currentCard == nil ? Theme.textMuted : Theme.textBright)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                if let card = model.currentCard {
                    Text(card.volumeLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(model.media.count.formatted()) files · \(ByteCountFormatter.shuttleString(model.totalMediaBytes))")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                    Text(breakdown)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    if let session = model.verifiedSession {
                        Label(
                            "Verified · \(session.totalFiles.formatted()) files · erase \(model.canWipe ? "unlocked" : "locked")",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.verified)
                        .padding(.top, 2)
                    }
                } else {
                    Text("No card connected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Insert a camera card, or choose a folder.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.currentCardIsEjectable {
                Button(action: model.ejectCard) {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .disabled(!model.canEject)
                .help("Eject \(model.currentCard?.volumeLabel ?? "card")")
            }
        }
    }

    private var breakdown: String {
        let counts = model.mediaCounts
        return MediaKind.allCases
            .compactMap { kind in counts[kind].map { "\($0.formatted()) \(kind.label)" } }
            .joined(separator: " · ")
    }

    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.progress.phase.label)
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textBright)
                Spacer()
                Text(model.progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(Theme.mono(9.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textBright)
            }
            MenuProgressBar(fraction: model.progress.fraction, color: Theme.textBright)
            Text(model.progress.currentItem)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Text("\(model.progress.completedFiles.formatted()) of \(model.progress.totalFiles.formatted()) files")
                    Spacer()
                    if let rate = model.throughputBytesPerSecond {
                        Text("\(ByteCountFormatter.shuttleString(Int64(rate)))/s")
                    }
                }
                .font(Theme.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func photosProgress(_ photos: PhotosImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("ADDING TO PHOTOS", systemImage: "photo.on.rectangle.angled")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textBright)
                Spacer()
                Text(photos.total > 0 ? "\(photos.completed)/\(photos.total)" : "Waiting for access")
                    .font(Theme.mono(9.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
            MenuProgressBar(fraction: photos.fraction, color: Theme.verified)
        }
    }

    private func bannerRow(_ banner: BannerMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.tone == .success ? "checkmark.circle.fill" : banner.tone.symbol)
                .font(.system(size: 11))
                .foregroundStyle(banner.tone.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(banner.message)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.dismissBanner) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Dismiss")
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if model.isBusy {
                if model.progress.phase != .erasing, model.progress.phase != .reVerifying {
                    MenuRow("Cancel Transfer", systemImage: "stop.circle", action: model.cancelTransfer)
                }
            } else if !model.isDestinationAvailable {
                MenuRow("Choose Destination…", systemImage: "folder.badge.questionmark") {
                    runAfterClosing(model.chooseDestination)
                }
            } else {
                MenuRow(
                    model.verifiedSession == nil ? "Transfer and Verify" : "Transfer Again",
                    systemImage: "arrow.down.doc",
                    shortcut: "⌘T",
                    action: model.startTransfer
                )
                .disabled(!model.canTransfer)
            }

            if model.isAddingToPhotos {
                MenuRow("Stop Adding to Photos", systemImage: "stop.circle", action: model.cancelAddToPhotos)
            } else {
                MenuRow("Add to Apple Photos", systemImage: "photo.on.rectangle.angled", shortcut: "⇧⌘P",
                        action: model.addToPhotos)
                    .disabled(!model.canAddToPhotos)
            }

            MenuRow("Scan for Media", systemImage: "arrow.clockwise", shortcut: "⌘R", action: model.scanNow)
                .disabled(model.isBusy)

            MenuRow("Choose Source…", systemImage: "folder.badge.plus") {
                runAfterClosing(model.chooseSource)
            }
            .disabled(model.isBusy)

            if model.selectedSourceURL != nil {
                MenuRow("Use Auto-Detect", systemImage: "sdcard", action: model.useAutomaticSource)
                    .disabled(model.isBusy)
            }

            MenuRow("Open Destination", systemImage: "folder", action: model.openDestination)
                .disabled(!model.isDestinationAvailable)

            MenuRow("Show Transfer Report", systemImage: "doc.text.magnifyingglass", action: model.openReport)
                .disabled(model.reportURL == nil)

            MenuRow("Open Photos", systemImage: "photo", action: model.openPhotosApp)

            MenuRow("Erase Card…", systemImage: "externaldrive.badge.xmark", destructive: true) {
                runAfterClosing {
                    openMainWindow()
                    model.requestErase()
                }
            }
            .disabled(!model.canWipe)
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Transfer new cards automatically", isOn: Binding(
                get: { model.settings.autoTransfer },
                set: { model.setAutoTransfer($0) }
            ))
            Toggle("Add to Photos after each transfer", isOn: Binding(
                get: { model.settings.addToPhotosAfterTransfer },
                set: { model.setAddToPhotosAfterTransfer($0) }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("RECENT")
            ForEach(model.activities.prefix(3)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute())
                        .foregroundStyle(Theme.textMuted)
                    Text(entry.message)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.mono(9.5))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Open Media Shuttle") {
                runAfterClosing(openMainWindow)
            }
            .buttonStyle(ShuttleButtonStyle(kind: .secondary))

            Spacer(minLength: 4)

            Button {
                runAfterClosing {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Quit Media Shuttle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panelFooterBackground)
    }

    // MARK: Helpers

    private func openMainWindow() {
        openWindow(id: "main")
        AppDelegate.presentMainWindow()
    }

    /// Open and save panels, Settings and the main window all need the panel out of the way first:
    /// it is a floating window that would otherwise sit on top of them until the next click.
    private func runAfterClosing(_ action: @escaping @MainActor () -> Void) {
        NSApp.windows
            .first { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra") }?
            .close()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }
}

private struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var destructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(
        _ title: String,
        systemImage: String,
        shortcut: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(destructive ? Theme.accent : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(destructive ? Theme.accent : Theme.textPrimary)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering && isEnabled ? Theme.fillStrong : .clear)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairlineSoft)
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
