// Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EquilMTMKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "EquilMTMKit", targets: ["EquilMTMKit"])],
    targets: [
        .target(name: "EquilMTMKit", path: "Sources/EquilMTMKit"),
        .testTarget(name: "EquilMTMKitTests", dependencies: ["EquilMTMKit"], path: "Tests/EquilMTMKitTests")
    ]
)
