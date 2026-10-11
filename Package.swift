// swift-tools-version: 6.2
import PackageDescription

// Waveform for iOS and macOS: an accurate voice waveform and an orb of dots that listens.
// `WaveformCore` has no UI and is where the accuracy and the speed live; `WaveformUI` is the SwiftUI
// views on top of it; `WaveformApp` is a macOS window to look at them (not a product).
let package = Package(
  name: "waveform-ios",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "WaveformCore", targets: ["WaveformCore"]),
    .library(name: "WaveformUI", targets: ["WaveformUI"]),
  ],
  targets: [
    .target(name: "WaveformCore"),
    .target(name: "WaveformUI", dependencies: ["WaveformCore"]),
    .executableTarget(
      name: "WaveformApp", dependencies: ["WaveformCore", "WaveformUI"], exclude: ["Info.plist"],
      // The microphone needs a usage description; a command-line build has no Info.plist, so one is
      // embedded in the executable.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/WaveformApp/Info.plist",
        ])
      ]),
    .testTarget(name: "WaveformCoreTests", dependencies: ["WaveformCore"]),
    .testTarget(name: "WaveformUITests", dependencies: ["WaveformUI", "WaveformCore"]),
  ]
)
