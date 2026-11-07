import SwiftUI

struct EraseConfirmationView: View {
    @Bindable var model: AppModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var phrase = ""
    @State private var acknowledged = false
    @FocusState private var phraseIsFocused: Bool

    private static let confirmationPhrase = "ERASE EVERYTHING"

    private var isConfirmed: Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines) == Self.confirmationPhrase && acknowledged
    }

    private var cardPath: String {
        model.currentCard?.rootURL.path ?? "the card"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erase \(model.currentCard?.volumeLabel ?? "card")")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(cardPath)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(16)

            Hairline()

            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Every media file is checked against its copy again before anything is deleted. "
                        + "Everything else on the card is deleted too, including camera databases and sidecar files."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("TYPE \(Self.confirmationPhrase) TO CONFIRM")
                    TextField("", text: $phrase, prompt: Text(Self.confirmationPhrase).foregroundStyle(Theme.textMuted))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Theme.fill)
                        .overlay(
                            Rectangle().strokeBorder(
                                phraseIsFocused ? Theme.primaryBorderStrong : Theme.primaryBorder,
                                lineWidth: 1
                            )
                        )
                        .focused($phraseIsFocused)
                }

                Toggle(isOn: $acknowledged) {
                    Text("I understand this permanently deletes all files and folders on \(cardPath).")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(ShuttleCheckboxStyle())
            }
            .padding(16)

            Hairline()

            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(ShuttleButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Erase card", action: onConfirm)
                    .buttonStyle(ShuttleButtonStyle(kind: .destructive))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfirmed || !model.canWipe)
            }
            .padding(12)
            .background(Theme.panelFooterBackground)
        }
        .frame(width: 500)
        .background(Theme.contentBackground)
        .onAppear { phraseIsFocused = true }
    }
}
