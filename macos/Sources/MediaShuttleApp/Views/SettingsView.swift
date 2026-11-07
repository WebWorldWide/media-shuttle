import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("APPEARANCE") {
                row("Theme") {
                    ShuttleSegmentedPicker(
                        selection: $model.settings.appearance,
                        options: [("System", "System"), ("Light", "Light"), ("Dark", "Dark")]
                    )
                    .frame(width: 240)
                }
            }

            section("TRANSFER") {
                toggle("Transfer automatically when a card is inserted", isOn: $model.settings.autoTransfer)
                divider
                toggle("Sort into dated folders (YYYY-MM-DD)", isOn: $model.settings.groupByDate)
                divider
                toggle("Notify when a transfer or erase finishes", isOn: $model.settings.showNotifications)
                divider
                toggle("Show the activity log", isOn: $model.settings.showActivityLog)
            }

            section("APPLE PHOTOS") {
                toggle("Add to Photos after each verified transfer", isOn: $model.settings.addToPhotosAfterTransfer)
                divider
                toggle("Include RAW files", detail: "Paired with the matching JPEG when there is one.",
                       isOn: $model.settings.photosIncludeRaw)
                divider
                toggle("Include videos", detail: "BRAW, R3D, MXF and AVCHD stay in the destination folder.",
                       isOn: $model.settings.photosIncludeVideos)
                divider
                HStack(spacing: 6) {
                    Button("Open Photos", action: model.openPhotosApp)
                        .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                    Button("Photos privacy settings…", action: model.openPhotosPrivacySettings)
                        .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }

            section("SYSTEM") {
                toggle(
                    "Open at login",
                    detail: "Managed by macOS in System Settings › General › Login Items.",
                    isOn: Binding(get: { model.startupEnabled }, set: { model.setLaunchAtLogin($0) })
                )
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.contentBackground)
        .onChange(of: model.settings) { _, _ in
            model.saveSettings()
        }
        .onChange(of: model.settings.addToPhotosAfterTransfer) { _, enabled in
            if enabled { model.preparePhotosAccess() }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .panelBox()
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 10)
    }

    private func toggle(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(ShuttleToggleStyle())
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Hairline(color: Theme.hairlineSoft)
    }
}
