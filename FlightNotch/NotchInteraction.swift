import Combine
import Foundation

@MainActor
final class NotchInteraction: ObservableObject {
    @Published private(set) var expanded = false
    @Published var pinned: Bool {
        didSet {
            preferences.set(pinned, forKey: "notchAlwaysOpen")
            scheduleVisibility()
        }
    }
    @Published var hideDelay: Double {
        didSet {
            preferences.set(hideDelay, forKey: "notchHideDelay")
            scheduleVisibility()
        }
    }
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    private let preferences: UserDefaults
    private var hoverTask: Task<Void, Never>?
    private var pointerInside = false
    private var settingsOpen = false
    private(set) var hideAt: Date?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        pinned = preferences.bool(forKey: "notchAlwaysOpen")
        let delay = preferences.double(forKey: "notchHideDelay")
        hideDelay = [3.0, 5.0, 10.0, 30.0].contains(delay) ? delay : 5
        expanded = pinned
    }

    var compactWidth: CGFloat { max(240, notchWidth + 168) }
    var expandedWidth: CGFloat { max(480, compactWidth) }
    var expandedHeight: CGFloat { notchHeight + 330 }

    func hover(_ inside: Bool) {
        pointerInside = inside
        scheduleVisibility()
    }

    func open() {
        guard !settingsOpen else { return }
        hoverTask?.cancel()
        expanded = true
        hideAt = !pinned && !pointerInside ? Date().addingTimeInterval(hideDelay) : nil
    }

    func togglePin() { pinned.toggle() }

    func setSettingsOpen(_ value: Bool) {
        settingsOpen = value
        hoverTask?.cancel()
        hideAt = nil
        if value { expanded = false }
        else { scheduleVisibility() }
    }

    // Called by the existing pointer timer. Using a deadline also makes clock
    // changes, cancellation and delayed run-loop ticks explicit and testable.
    func tick(now: Date = Date()) {
        if let hideAt, now >= hideAt, !pinned, !pointerInside, !settingsOpen {
            expanded = false
            self.hideAt = nil
        }
    }

    private func scheduleVisibility() {
        hoverTask?.cancel()
        hideAt = nil
        guard !settingsOpen else { return }
        if pinned { expanded = true; return }
        if pointerInside {
            guard !expanded else { return }
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                self?.expanded = true
            }
        } else if expanded {
            hideAt = Date().addingTimeInterval(hideDelay)
        }
    }
}
