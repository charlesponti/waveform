// swift-tools-version: 6.2
import PackageDescription

// A voice waveform, tried outside Thames. `WaveformCore` has no UI and is where the accuracy and
// the speed live; `WaveformApp` is a window to look at it.
let package = Package(
  name: "Waveform",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [.library(name: "WaveformCore", targets: ["WaveformCore"])],
  targets: [
    .target(name: "WaveformCore"),
    .executableTarget(
      name: "WaveformApp", dependencies: ["WaveformCore"], exclude: ["Info.plist"],
      // The microphone needs a usage description; a command-line build has no Info.plist, so one is
      // embedded in the executable.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/WaveformApp/Info.plist",
        ])
      ]),
    .testTarget(name: "WaveformCoreTests", dependencies: ["WaveformCore"]),
  ]
)
