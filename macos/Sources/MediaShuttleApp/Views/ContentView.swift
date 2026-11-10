import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingEraseConfirmation = false
    @State private var eraseTarget: AppModel.EraseTarget?

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model)
            Hairline()
            HStack(spacing: 0) {
                SourcePanel(model: model)
                    .frame(width: 280)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                OperationsView(
                    model: model,
                    showEraseConfirmation: {
                        // Captured as the sheet opens, and checked again on confirm.
                        eraseTarget = model.currentEraseTarget
                        showingEraseConfirmation = eraseTarget != nil
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.contentBackground)
        // Draw through the hidden title bar so the wordmark sits on the same
        // row as the traffic lights instead of in a band beneath them.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1_020, minHeight: 620)
        .onAppear {
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            presentRequestedErase()
        }
        .onChange(of: model.eraseRequested) { _, _ in
            presentRequestedErase()
        }
        .sheet(isPresented: $showingEraseConfirmation) {
            EraseConfirmationView(model: model) {
                showingEraseConfirmation = false
                if let eraseTarget {
                    model.wipeCard(expecting: eraseTarget)
                }
                eraseTarget = nil
            } onCancel: {
                showingEraseConfirmation = false
                eraseTarget = nil
            }
        }
    }

    /// Erase asked for from the menu bar. The same capture-then-recheck as the erase button.
    private func presentRequestedErase() {
        guard model.eraseRequested else { return }
        model.eraseRequested = false
        guard !showingEraseConfirmation else { return }
        eraseTarget = model.currentEraseTarget
        showingEraseConfirmation = eraseTarget != nil
    }
}

/// Replaces the stock toolbar. The window uses `.hiddenTitleBar`, so the
/// traffic lights float over this bar — hence the leading inset.
private struct TitleBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 20)

            Text("MEDIA SHUTTLE")
                .font(Theme.mono(10.5, .semibold))
                .tracking(1.15)
                .foregroundStyle(Theme.textPrimary)

            StatusPill(text: model.topStatus, tone: model.statusTone)

            Spacer(minLength: 12)

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Settings")
        }
        .padding(.leading, 78)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(Theme.chromeBackground)
        .background(TrafficLightAligner(barHeight: Self.height))
    }

    static let height: CGFloat = 48
}

private struct StatusPill: View {
    let text: String
    let tone: AppStatusTone

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(tone.color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(Theme.mono(9.5))
                .tracking(0.7)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.fill)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Media status: \(text)")
    }
}
