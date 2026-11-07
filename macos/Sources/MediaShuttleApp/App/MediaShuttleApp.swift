import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openMainWindow: (() -> Void)?

    /// True when macOS started the app at login — Login Items, which `SMAppService.mainApp`
    /// registers — rather than someone opening it. `--background` forces the same path so it can
    /// be exercised without logging out.
    private var launchedInBackground: Bool {
        if ProcessInfo.processInfo.arguments.contains("--background") { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated { DemoFrames.runIfRequested() }
        #endif
        let background = launchedInBackground
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopen(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )

        // Starting at login used to raise the window and take the foreground, in front of whatever
        // the reader had opened. A launch nobody asked for stays out of the way: no Dock icon, no
        // activation, no window — the menu bar extra is the whole of its presence until asked for
        // more. The window is ordered out rather than closed, so the card watcher its `task` owns
        // keeps running and an unattended transfer still happens.
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        if !background {
            NSApp.activate(ignoringOtherApps: true)
        }

        // The packaged .app gets its Dock icon from Info.plist's CFBundleIconName, which
        // resolves through the Assets.car that scripts/package-macos.sh compiles from
        // Resources/MediaShuttle.icon. That key is inert for unbundled dev runs
        // (`swift run`), so render the same brand mark at launch to keep the Dock icon
        // consistent while developing.
        if !Bundle.isPackagedApp {
            NSApp.applicationIconImage = AppMark.renderedDockIcon()
        }

        if background {
            // The scene builds its window around this callback, so hide on the next turn of the
            // run loop, once there is something to hide.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.orderOut(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // A closed SwiftUI window is removed from NSApp.windows. Raising a window that no longer
    // exists cannot reopen it, and the delegate adaptor does not reliably forward reopen events.
    // Handle the launch-services event directly and let SwiftUI recreate the scene when needed.
    @MainActor @objc private func handleReopen(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.title == "Media Shuttle" }) {
            Self.openMainWindow?()
        }
        Self.presentMainWindow()
    }

    /// Brings the app forward from a background launch. The activation policy is raised first:
    /// an `.accessory` app can take the foreground but has no Dock icon and no place in the
    /// application switcher, which is wrong once it is showing a window.
    @MainActor
    static func presentMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        // With Settings open, "the first window that can become main" was often the Settings
        // window, so Open Media Shuttle raised Settings and left the main window behind it.
        let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }
            ?? NSApp.windows.first { $0.canBecomeMain && $0.title == "Media Shuttle" }
        main?.makeKeyAndOrderFront(nil)
    }
}

@main
struct MediaShuttleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Media Shuttle", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.appearance)
                .task { await model.start() }
        }
        .defaultSize(width: 1_180, height: 720)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Camera Card Folder…", action: model.chooseSource)
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.isBusy)
            }
            CommandMenu("Media") {
                Button("Scan for Camera Media") { model.scanNow() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isBusy)

                Button(model.isDestinationAvailable ? "Transfer and Verify" : "Choose Destination…") {
                    if model.isDestinationAvailable {
                        model.startTransfer()
                    } else {
                        model.chooseDestination()
                    }
                }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(model.isDestinationAvailable ? !model.canTransfer : model.isBusy)

                Button("Add to Apple Photos") { model.addToPhotos() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canAddToPhotos)

                Button("Eject Card") { model.ejectCard() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!model.canEject)

                Divider()

                Button("Open Destination") { model.openDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.isDestinationAvailable)

                Button("Show Transfer Report") { model.openReport() }
                    .disabled(model.reportURL == nil)
            }
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.appearance)
        }

        MenuBarExtra {
            MenuBarView(model: model)
                .preferredColorScheme(model.appearance)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
