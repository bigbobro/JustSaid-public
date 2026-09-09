// Public manifest template.
//
// This is the canonical target graph with every verification executable
// removed: Verification/ is test-fixture surface and is not published. The
// exporter checks the package identity, dependency pin, product list and
// Swift language mode against the canonical Package.swift, and then compares
// every surviving target whole -- kind, path, and every other labelled
// argument of the declaration, normalised -- across every PackageDescription
// target spelling, so this template is exactly the canonical graph minus its
// Verification/ targets, before mapping this file to the candidate's
// Package.swift.
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "JustSaid",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "JustSaid", targets: ["JustSaidApp"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/k2-fsa/sherpa-onnx",
      revision: "116a44e72c5bb631dcdbdb9c176f0304f5fc6fb0"
    )
  ],
  targets: [
    .target(
      name: "JustSaidCore",
      dependencies: [
        .product(name: "sherpa-onnx", package: "sherpa-onnx")
      ],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AVFAudio"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("Security"),
        .linkedFramework("Speech"),
      ]
    ),
    .target(
      name: "JustSaidUI",
      dependencies: ["JustSaidCore"],
      linkerSettings: [
        .linkedFramework("Carbon")
      ]
    ),
    .executableTarget(
      name: "JustSaidApp",
      dependencies: ["JustSaidCore", "JustSaidUI"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
