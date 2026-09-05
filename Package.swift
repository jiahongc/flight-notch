// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightNotch",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FlightCore", targets: ["FlightCore"])],
    targets: [
        .target(name: "FlightCore", path: "FlightNotch", exclude: ["FlightNotchApp.swift", "FlightNotchView.swift", "Info.plist", "FlightNotch.entitlements"]),
        .testTarget(name: "FlightCoreTests", dependencies: ["FlightCore"], path: "FlightNotchTests")
    ]
)
