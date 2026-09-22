import XCTest
@testable import FlightCore

@MainActor
final class NotchInteractionTests: XCTestCase {
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "NotchInteractionTests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
    }

    func testAutoHideDeadlineAndPointerReentry() throws {
        let state = NotchInteraction(preferences: preferences)
        state.open()
        let deadline = try XCTUnwrap(state.hideAt)
        state.tick(now: deadline.addingTimeInterval(-1))
        XCTAssertTrue(state.expanded)
        state.hover(true)
        state.tick(now: deadline.addingTimeInterval(20))
        XCTAssertTrue(state.expanded, "Do not hide while the user is interacting")
        XCTAssertNil(state.hideAt)
        state.hover(false)
        state.tick(now: try XCTUnwrap(state.hideAt).addingTimeInterval(1))
        XCTAssertFalse(state.expanded)
    }

    func testAlwaysOpenPersistsAndIgnoresDeadline() {
        let state = NotchInteraction(preferences: preferences)
        state.pinned = true
        state.hover(false)
        state.tick(now: .distantFuture)
        XCTAssertTrue(state.expanded)
        let restored = NotchInteraction(preferences: preferences)
        XCTAssertTrue(restored.pinned)
        XCTAssertTrue(restored.expanded)
        restored.pinned = false
        restored.tick(now: .distantFuture)
        XCTAssertFalse(restored.expanded)
    }

    func testSettingsTemporarilyCollapsesEvenAlwaysOpen() async throws {
        let state = NotchInteraction(preferences: preferences)
        state.pinned = true
        state.setSettingsOpen(true)
        state.hover(true)
        state.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(state.expanded)
        XCTAssertTrue(state.pinned, "Opening Settings must preserve the user's visibility preference")
        state.setSettingsOpen(false)
        XCTAssertTrue(state.expanded)
    }

    func testDelayPersistsAndCancelledHoverDoesNotReopen() async throws {
        let state = NotchInteraction(preferences: preferences)
        state.hideDelay = 30
        XCTAssertEqual(NotchInteraction(preferences: preferences).hideDelay, 30)
        state.hover(true)
        state.hover(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(state.expanded)
        state.hover(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !state.expanded && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(state.expanded, "Hover should eventually expand, allowing for a busy executor")
    }

    func testSizePersistsAndChangesBothPanelStates() {
        let state = NotchInteraction(preferences: preferences)
        state.notchWidth = 185
        XCTAssertEqual(state.compactWidth, 353)
        XCTAssertEqual(state.expandedWidth, 480)
        state.resize(from: 1, translation: -500)
        XCTAssertEqual(state.compactWidth, 319.4, accuracy: 0.01)
        XCTAssertEqual(state.expandedWidth, 440)
        XCTAssertEqual(state.expandedHeight, state.notchHeight + 246, accuracy: 0.01)
        let restored = NotchInteraction(preferences: preferences)
        XCTAssertEqual(restored.size, 0.8)
        restored.resize(from: 1, translation: 500)
        XCTAssertEqual(restored.expandedWidth, 576)
        XCTAssertEqual(restored.expandedHeight, restored.notchHeight + 334, accuracy: 0.01)
        preferences.set(4.0, forKey: "notchSize")
        XCTAssertEqual(NotchInteraction(preferences: preferences).size, 1.2)
    }
}
