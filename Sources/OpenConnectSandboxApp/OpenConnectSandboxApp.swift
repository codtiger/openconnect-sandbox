import AppKit
import Foundation
import OpenConnectSandboxCore
import SwiftUI

@main
struct OpenConnectSandboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        } label: {
            MenuBarStatusLabel(hasActiveConnections: model.hasActiveConnections)
        }

        Window("OpenConnect Sandbox", id: "connections") {
            ProfilesWindow()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 980, height: 650)

        Settings {
            AppSettingsView()
                .environmentObject(model)
                .frame(width: 620, height: 290)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()
        installSignalHandlers()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let activeModel = model ?? AppModel.shared
        Task { @MainActor in
            await activeModel.shutdownAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        try? FileManager.default.removeItem(at: SandboxPaths.runtimeURL())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        if let window = sender.windows.first(where: { $0.title == "OpenConnect Sandbox" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .showConnectionsWindow, object: nil)
        }
        return true
    }

    @objc private func workspaceWillSleep() {
        guard UserDefaults.standard.object(forKey: "disconnectOnSleep") as? Bool ?? true else { return }
        Task { @MainActor in (model ?? AppModel.shared).disconnectAll() }
    }

    private func installSignalHandlers() {
        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func configureApplicationIcon() {
        guard let symbol = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: "OpenConnect Sandbox"
        ) else { return }
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        icon.lockFocus()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 448, height: 448), xRadius: 100, yRadius: 100).fill()
        let configured = symbol.withSymbolConfiguration(.init(pointSize: 280, weight: .semibold)) ?? symbol
        configured.draw(
            in: NSRect(x: 116, y: 116, width: 280, height: 280),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        icon.unlockFocus()
        icon.isTemplate = false
        NSApp.applicationIconImage = icon
    }
}

extension Notification.Name {
    static let showConnectionsWindow = Notification.Name("OpenConnectSandbox.showConnectionsWindow")
}

private struct MenuBarStatusLabel: View {
    @Environment(\.openWindow) private var openWindow
    let hasActiveConnections: Bool

    var body: some View {
        Label(
            "OpenConnect Sandbox",
            systemImage: hasActiveConnections ? "lock.shield.fill" : "lock.shield"
        )
        .onReceive(NotificationCenter.default.publisher(for: .showConnectionsWindow)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "connections")
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "OpenConnect Sandbox" })?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
