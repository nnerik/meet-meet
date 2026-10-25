import AppKit
import SwiftUI
import MeetMeetCore

@main
enum MeetMeetApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Meet Meet")
        item.button?.toolTip = "Meet Meet"

        let menu = NSMenu()
        let status = menu.addItem(withTitle: "Calendar setup is not available yet", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: "Quit Meet Meet", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meet Meet Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FoundationSettingsView())
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}

private struct FoundationSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Meet Meet", systemImage: "calendar").font(.title2.bold())
            Text("The app foundation is ready.")
            Text("Calendar selection, countdowns, and alerts are the next implementation steps. No calendar permission has been requested.")
                .foregroundStyle(.secondary)
            Text("macOS 26+ · Swift 6 · local calendar data only")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 480, alignment: .leading)
    }
}
