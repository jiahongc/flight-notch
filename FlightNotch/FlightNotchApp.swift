import AppKit
import Combine
import SwiftUI

@main
struct FlightNotchApp: App {
    @NSApplicationDelegateAdaptor(FlightNotchDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Flight Notch", systemImage: "airplane") {
            FlightMenu(store: delegate.store, showFlights: delegate.showFlights, showSettings: delegate.showSettings)
        }
    }
}

private struct FlightMenu: View {
    @ObservedObject var store: FlightStore
    let showFlights: () -> Void
    let showSettings: () -> Void

    var body: some View {
        Button("Show flights", action: showFlights)
        Button("Settings…", action: showSettings).keyboardShortcut(",")
        Divider()
        Button(store.paused ? "Resume tracking" : "Pause tracking") { store.setPaused(!store.paused) }
        Divider()
        Button("Quit Flight Notch") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class FlightNotchWindow: BoringNotchWindow {
    // Allow keyboard focus when clicked, while the nonactivatingPanel
    // style avoids activating the app on hover.
    override var canBecomeKey: Bool { true }
}

@MainActor
final class FlightNotchDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = FlightStore()
    let interaction = NotchInteraction()
    private var panel: FlightNotchWindow?
    private var settings: NSWindowController?
    private var pointerTimer: Timer?
    private var lastInside = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        pointerTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.close()
        settings?.close()
    }

    func showFlights() {
        settings?.close()
        interaction.open()
        panel?.orderFrontRegardless()
    }

    func showSettings() {
        interaction.setSettingsOpen(true)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Flight Notch Settings"
            window.contentView = NSHostingView(rootView: FlightSettingsView(store: store, interaction: interaction))
            window.level = (panel?.level ?? .mainMenu) + 1
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()
            settings = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settings?.window else { return }
        interaction.setSettingsOpen(false)
    }

    private func createPanel() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        // Preserve Boring Notch’s physical camera-gap math and top-centered panel lifecycle.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            interaction.notchWidth = screen.frame.width - left.width - right.width + 4
        } else { interaction.notchWidth = 0 }
        interaction.notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 30
        let size = NSSize(width: interaction.expandedWidth + 40, height: interaction.expandedHeight + 30)
        if panel == nil {
            panel = FlightNotchWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            panel?.contentView = NSHostingView(rootView: FlightNotchView(store: store, interaction: interaction, showSettings: { [weak self] in self?.showSettings() }))
        }
        panel?.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        panel?.orderFrontRegardless()
        updatePointer()
    }

    private func updatePointer() {
        guard let panel, panel.isVisible else { return }
        let width = interaction.expanded ? interaction.expandedWidth : interaction.compactWidth
        let height = interaction.expanded ? interaction.expandedHeight : interaction.notchHeight
        let rect = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height, width: width, height: height)
        let inside = rect.contains(NSEvent.mouseLocation)
        // Keep the transparent area of the large animation window click-through.
        panel.ignoresMouseEvents = !inside
        if inside != lastInside {
            lastInside = inside
            interaction.hover(inside)
        }
        interaction.tick()
    }

    @objc private func screenChanged() { createPanel() }
    @objc private func sleep() { store.setSleeping(true); panel?.orderOut(nil) }
    @objc private func wake() { store.setSleeping(false); createPanel() }
}
