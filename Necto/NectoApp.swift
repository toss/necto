//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import SwiftUI
import UserNotifications

/// SwiftUI owns only the chrome: window, sidebar and target selection.
/// Every feature screen is a web plugin.
@main
struct NectoApp: App {
    @State private var model = NectoAppModel()
    @NSApplicationDelegateAdaptor(NectoAppDelegate.self) private var delegate
    @AppStorage(NectoLanguage.key) private var language = NectoLanguage.system.rawValue

    private var selectedLanguage: NectoLanguage { NectoLanguage(rawValue: language) ?? .system }

    var body: some Scene {
        WindowGroup("Necto") {
            ContentView(model: model)
                .environment(\.locale, selectedLanguage.locale)
        }
        .defaultSize(width: 1100, height: 720)
        // No title bar of its own. The toolbar carries the plugin's identity, and AppKit
        // reflows it around the traffic lights when the sidebar closes.
        .windowStyle(.hiddenTitleBar)
        // Settings is a screen of the app, not a window of its own, so the standard
        // shortcut opens that screen instead of a second place to look.
        .commands {
            // A panel is a web page, so the system find bar never appears for it.
            // This is the one that does.
            CommandGroup(after: .textEditing) {
                Button(NectoL10n.text("Find…")) {
                    NotificationCenter.default.post(name: .nectoFindInPanel, object: nil)
                }
                    .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button(NectoL10n.text("Settings…")) {
                    NotificationCenter.default.post(name: .nectoShowSettings, object: nil)
                }
                    .keyboardShortcut(",", modifiers: .command)
            }

            // The same preference the Settings screen writes, reachable without leaving
            // whatever is on screen.
            CommandGroup(after: .toolbar) {
                Button(NectoL10n.text("Bigger Text")) { nudgeText(by: NectoTextSize.step) }
                    .keyboardShortcut("+", modifiers: .command)
                Button(NectoL10n.text("Smaller Text")) { nudgeText(by: -NectoTextSize.step) }
                    .keyboardShortcut("-", modifiers: .command)
                Button(NectoL10n.text("Actual Size")) { setText(NectoTextSize.base) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }
    }
}

private func nudgeText(by delta: CGFloat) {
    let stored = UserDefaults.standard.object(forKey: NectoTextSize.key) as? Double
    setText(CGFloat(stored ?? Double(NectoTextSize.base)) + delta)
}

private func setText(_ points: CGFloat) {
    UserDefaults.standard.set(Double(NectoTextSize.clamp(points)), forKey: NectoTextSize.key)
}

extension Notification.Name {
    static let nectoShowSettings = Notification.Name("NectoShowSettings")
    static let nectoFindInPanel = Notification.Name("NectoFindInPanel")
}

/// Brings the window to the front even when launched outside an app bundle.
final class NectoAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
