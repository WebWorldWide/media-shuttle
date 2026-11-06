import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.settings.appearance) {
                    Text("Use System Setting").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Transfer") {
                Toggle("Transfer automatically when a card is connected", isOn: $model.settings.autoTransfer)
                Toggle("Group files into YYYY-MM-DD folders", isOn: $model.settings.groupByDate)
                Toggle("Show completion notifications", isOn: $model.settings.showNotifications)
                Toggle("Show the activity log", isOn: $model.settings.showActivityLog)
            }

            Section {
                Toggle("Add to Apple Photos after each verified transfer", isOn: $model.settings.addToPhotosAfterTransfer)
                Toggle("Include RAW files (paired with their JPEG when there is one)", isOn: $model.settings.photosIncludeRaw)
                Toggle("Include videos", isOn: $model.settings.photosIncludeVideos)
                HStack {
                    Button("Open Photos", action: model.openPhotosApp)
                    Button("Photos Privacy Settings…", action: model.openPhotosPrivacySettings)
                }
            } header: {
                Text("Apple Photos")
            } footer: {
                Text(
                    "Photos copies each file into its library, and iCloud Photos syncs it to your other "
                        + "devices. Files already added are remembered and never added twice. BRAW, R3D, MXF "
                        + "and AVCHD stay in the destination folder only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("System") {
                Toggle("Launch Media Shuttle at login", isOn: Binding(
                    get: { model.startupEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Launch at Login is managed by macOS in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 560, height: 720)
        .onChange(of: model.settings) { _, _ in
            model.saveSettings()
        }
        .onChange(of: model.settings.addToPhotosAfterTransfer) { _, enabled in
            if enabled { model.preparePhotosAccess() }
        }
    }
}
