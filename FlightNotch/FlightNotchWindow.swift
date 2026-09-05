//
//  FlightNotchWindow.swift
//  Flight Notch
//
//  Created by Harsh Vardhan  Goswami  on 06/08/24.
//  Adapted from Boring Notch's BoringNotchWindow.swift (GPL-3.0).
//  Modified for Flight Notch on 2026-09-05: renamed and enabled keyboard focus.
//  See LICENSE and THIRD_PARTY_LICENSES.
//

import Cocoa

@MainActor
final class FlightNotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
    }

    override var canBecomeKey: Bool {
        // Accept keyboard focus on click; nonactivatingPanel keeps hover passive.
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
