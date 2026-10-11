import AppKit
import SwiftUI
import WaveformCore
import WaveformUI

// Usage:
//   swift run -c release WaveformApp                       draw the microphone
//   swift run -c release WaveformApp --file voice.m4a      play a file and draw it
//   swift run -c release WaveformApp --snapshot out.png    write a picture of a made-up voice
//   swift run -c release WaveformApp --spectrum-snapshot out.png   the spectrum orb at four moments
//   swift run -c release WaveformApp --bench               how fast the column maker is

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
  arguments.firstIndex(of: flag).flatMap { index in
    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
  }
}

func prefilled(seconds: Double) -> ColumnRing {
  let ring = ColumnRing(capacity: 8192)
  let builder = ColumnBuilder(sampleRate: 48_000, columnsPerSecond: 120, windowBlocks: 3)
  let signal = Synthesize.speechLike(seconds: seconds)
  signal.withUnsafeBufferPointer { buffer in
    builder.feed(buffer.baseAddress!, count: buffer.count) { ring.append($0) }
  }
  return ring
}

func prefilledSpectrum(seconds: Double) -> SpectrumRing {
  let ring = SpectrumRing(bands: 24, capacity: 8192)
  let builder = SpectrumBuilder(sampleRate: 48_000)
  let signal = Synthesize.vowels(seconds: seconds)
  signal.withUnsafeBufferPointer { buffer in
    builder.feed(buffer.baseAddress!, count: buffer.count) { ring.append($0) }
  }
  return ring
}

if let path = value(after: "--spectrum-snapshot") {
  MainActor.assumeIsolated {
    let moments = [1.4, 2.2, 3.4, 4.6]
    var images: [NSImage] = []
    for seconds in moments {
      let view = SpectrumOrbView(spectrum: prefilledSpectrum(seconds: seconds), showStats: false, turning: false)
        .frame(width: 360, height: 360)
        .background(Color(red: 0.03, green: 0.06, blue: 0.06))
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      images.append(renderer.nsImage!)
    }
    let sheet = NSImage(size: NSSize(width: 360 * images.count, height: 360))
    sheet.lockFocus()
    for (i, image) in images.enumerated() { image.draw(in: NSRect(x: 360 * i, y: 0, width: 360, height: 360)) }
    sheet.unlockFocus()
    let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
  }
  exit(0)
}

if arguments.contains("--bench") {
  let seconds = 600.0
  let signal = Synthesize.speechLike(seconds: seconds)
  let builder = ColumnBuilder(sampleRate: 48_000, columnsPerSecond: 120, windowBlocks: 3)
  let ring = ColumnRing(capacity: 8192)
  let began = ContinuousClock.now
  signal.withUnsafeBufferPointer { buffer in
    var start = 0
    while start < buffer.count {  // 512 at a time, like the audio callback
      let n = min(512, buffer.count - start)
      builder.feed(buffer.baseAddress! + start, count: n) { ring.append($0) }
      start += n
    }
  }
  let took = began.duration(to: .now)
  let ms = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
  print(String(format: "%.0f s of audio in %.1f ms: %.0fx real time, %.2f ns a sample, %.1f µs a 512-sample buffer",
    seconds, ms, seconds * 1000 / ms, ms * 1e6 / (seconds * 48_000), ms * 1000 / (seconds * 48_000 / 512)))
  exit(0)
}

if let path = value(after: "--snapshot") {
  MainActor.assumeIsolated {
    let ring = prefilled(seconds: 12)
    let view = WaveformView(ring: ring, showStats: false)
      .frame(width: 900, height: 260)
      .background(Color(red: 0.03, green: 0.06, blue: 0.06))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { fatalError("could not render") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
  }
  exit(0)
}

if let path = value(after: "--orb-snapshot") {
  MainActor.assumeIsolated {
    // Several moments of the same made-up voice: silence, a word starting, a loud word, fading out.
    let moments: [(String, Double)] = [("quiet", 1.9), ("word", 2.6), ("loud", 3.15), ("after", 4.3)]
    var images: [NSImage] = []
    for (_, seconds) in moments {
      let view = OrbView(ring: prefilled(seconds: seconds), showStats: false, turning: false)
        .frame(width: 360, height: 360)
        .background(Color(red: 0.03, green: 0.06, blue: 0.06))
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      images.append(renderer.nsImage!)
    }
    let sheet = NSImage(size: NSSize(width: 360 * images.count, height: 360))
    sheet.lockFocus()
    for (i, image) in images.enumerated() { image.draw(in: NSRect(x: 360 * i, y: 0, width: 360, height: 360)) }
    sheet.unlockFocus()
    let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
  }
  exit(0)
}

struct WaveformApp: App {
  @State private var live = LiveInput(ring: ColumnRing(capacity: 8192))
  @State private var scale: Scale = .decibels(floor: -60)
  @State private var logarithmic = true
  enum Look: String, CaseIterable { case bars = "Bars", orb = "Orb", spectrum = "Spectrum orb" }
  @State private var look = Look.spectrum
  @State private var status = ""

  var body: some Scene {
    WindowGroup("Waveform") {
      VStack(spacing: 0) {
        Group {
          switch look {
          case .bars: WaveformView(ring: live.ring, scale: scale)
          case .orb: OrbView(ring: live.ring, clock: live.clock, scale: scale)
          case .spectrum: SpectrumOrbView(spectrum: live.spectrum, clock: live.clock)
          }
        }
        .background(Color(red: 0.03, green: 0.06, blue: 0.06))
        HStack {
          Picker("Look", selection: $look) {
            ForEach(Look.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).labelsHidden()
          Toggle("Decibels", isOn: $logarithmic)
            .onChange(of: logarithmic) { scale = logarithmic ? .decibels(floor: -60) : .linear }
        }.padding(8)
        if !status.isEmpty {
          Text(status).font(.callout).foregroundStyle(.red).padding([.horizontal, .bottom], 8)
        }
      }
      .frame(minWidth: 600, minHeight: 240)
      .task {
        do {
          if let file = value(after: "--file") {
            try live.play(file: URL(fileURLWithPath: file))
          } else {
            try await live.startMicrophone()
          }
        } catch {
          print("Could not start audio: \(error)")
          status = "\(error)"
        }
      }
    }
  }
}

NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
WaveformApp.main()
