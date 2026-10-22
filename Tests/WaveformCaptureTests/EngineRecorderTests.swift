import AVFoundation
import Foundation
import Testing
import WaveformCore

@testable import WaveformCapture

/// The recorder runs a real `AVAudioEngine` in offline rendering mode, fed by a real file through a
/// player node, so no microphone or speaker is involved. What it writes is a real file, read back and
/// checked against the settings each app uses: Ponte's 16 kHz WAV for on-device transcription, and
/// Thames's 24 kHz AAC with the spectrum its orb draws.
///
/// This is the point of the shared engine: one implementation, one suite, both apps covered.
@Suite struct EngineRecorderTests {
  static let inputRate = 44_100.0

  // MARK: - The offline rig

  /// A temporary directory that removes itself when the test ends.
  struct Scratch: ~Copyable {
    let url: URL
    init() {
      url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("waveform-capture-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private func offlineEngine() throws -> (AVAudioEngine, AVAudioPlayerNode) {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let format = AVAudioFormat(standardFormatWithSampleRate: Self.inputRate, channels: 1)!
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return (engine, player)
  }

  /// A sine wave at `hertz`, amplitude `amplitude`, written as a float32 WAV to play into the engine.
  private func tone(
    seconds: Double, hertz: Double, amplitude: Float = 0.5, in dir: borrowing Scratch
  ) throws -> AVAudioFile {
    let url = dir.file("tone-\(UUID().uuidString).wav")
    var writer: AVAudioFile? = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.inputRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
      ])
    let count = Int(seconds * Self.inputRate)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: writer!.processingFormat, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
      buffer.floatChannelData![0][i] =
        Float(sin(Double(i) / Self.inputRate * hertz * 2 * .pi)) * amplitude
    }
    try writer!.write(from: buffer)
    writer = nil  // releasing the writer finishes the file, so it can be read
    return try AVAudioFile(forReading: url)
  }

  private func render(_ engine: AVAudioEngine, seconds: Double) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var left = Int(seconds * Self.inputRate)
    while left > 0 {
      let n = min(left, 4096)
      _ = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
      left -= n
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  // MARK: - Ponte: a WAV the on-device engines can read

  @Test func recordsTheWaveformTranscriptionWants() async throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    let url = dir.file("out.wav")
    player.scheduleFile(
      try tone(seconds: 1, hertz: 440, in: dir), at: nil, completionHandler: nil)
    try recorder.start(to: url)
    player.play()
    try render(engine, seconds: 1)
    await waitUntil { recorder.columns.count >= 100 }
    let milliseconds = try recorder.stop()

    #expect(recorder.path == url.path)
    #expect((850...1_050).contains(milliseconds))

    // The file must be exactly what whisper.cpp and Parakeet are handed.
    let written = try AVAudioFile(forReading: url)
    #expect(written.fileFormat.sampleRate == 16_000)
    #expect(written.fileFormat.channelCount == 1)
    #expect(written.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
    #expect(written.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(abs(Double(written.length) / 16_000 * 1_000 - milliseconds) < 150)

    // Columns for the orb: about 120 a second, and the tone is genuinely loud in them.
    #expect((100...135).contains(recorder.columns.count))
    var frame = [Column](repeating: .silent, count: 8)
    let (real, _) = frame.withUnsafeMutableBufferPointer {
      recorder.columns.snapshot(8, into: $0.baseAddress!)
    }
    #expect(real >= 8)
    let last = frame[frame.count - 1]
    #expect(last.level > 0.2, "a 440 Hz tone at half scale should be plainly audible")
    #expect(abs(last.high - 0.5) < 0.1, "the peak is the tone's amplitude")
    #expect(last.level > 0.2 * 0.4)
  }

  // MARK: - Thames: AAC plus the spectrum its orb draws

  @Test func recordsTheStreamAndItsSpectrum() async throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .streamingSpeech, engine: engine, source: player)
    let url = dir.file("out.m4a")
    player.scheduleFile(
      try tone(seconds: 1, hertz: 440, in: dir), at: nil, completionHandler: nil)
    try recorder.start(to: url)
    player.play()
    try render(engine, seconds: 1)
    await waitUntil { (recorder.spectrum?.count ?? 0) >= 100 }
    let milliseconds = try recorder.stop()

    let written = try AVAudioFile(forReading: url)
    #expect(written.fileFormat.sampleRate == 24_000)
    #expect(written.fileFormat.channelCount == 1)
    #expect((850...1_050).contains(milliseconds))
    #expect(abs(Double(written.length) / 24_000 * 1_000 - milliseconds) < 150)

    let spectrum = try #require(recorder.spectrum)
    #expect((90...122).contains(spectrum.count))

    // A 440 Hz tone lights one band much more than the rest of the spectrum.
    var frame = [Float](repeating: 0, count: 24 * 8)
    let (real, _) = frame.withUnsafeMutableBufferPointer {
      spectrum.snapshot(8, into: $0.baseAddress!)
    }
    #expect(real >= 8)
    let last = Array(frame[(24 * 7)...])
    #expect(last.max()! > 0.05)
    #expect(last.max()! > 4 * last.sorted()[12])
  }

  @Test func aTranscriptionRecordingPaysForNoSpectrum() {
    #expect(CaptureSettings.localTranscription.spectrumBands == nil)
    #expect(CaptureSettings.streamingSpeech.spectrumBands == 24)
    #expect(CaptureSettings.localTranscription.fileExtension == "wav")
    #expect(CaptureSettings.streamingSpeech.fileExtension == "m4a")
  }

  // MARK: - The state machine, shared by both apps

  @Test func stopsCleanlyAndTwiceIsHarmless() throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    try recorder.start(to: dir.file("silent.wav"))
    let first = try recorder.stop()
    #expect(first == 0)
    #expect(try recorder.stop() == 0)
  }

  @Test func reportsHowLongItHasBeenRecording() async throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    player.scheduleFile(
      try tone(seconds: 1, hertz: 440, in: dir), at: nil, completionHandler: nil)
    try recorder.start(to: dir.file("clock.wav"))
    player.play()
    try render(engine, seconds: 0.5)
    await waitUntil { recorder.seconds > 0.3 }
    #expect(abs(recorder.seconds - 0.5) < 0.15, "the clock counts what has been written")
    _ = try recorder.stop()
  }

  @Test func aRouteChangeKeepsRecordingToTheSameFile() async throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    let url = dir.file("route.wav")
    player.scheduleFile(
      try tone(seconds: 1, hertz: 440, in: dir), at: nil, completionHandler: nil)
    try recorder.start(to: url)
    player.play()
    try render(engine, seconds: 0.5)
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    try render(engine, seconds: 0.5)
    await waitUntil { recorder.columns.count >= 60 }
    let milliseconds = try recorder.stop()
    #expect(milliseconds > 700)
    #expect(try AVAudioFile(forReading: url).length > 0)
  }

  @Test func aFailedRestartAfterARouteChangeMakesTheRecordingIncomplete() async throws {
    let dir = Scratch()
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    try recorder.start(to: dir.file("cut.wav"))
    struct Gone: LocalizedError { var errorDescription: String? { "the headset went away" } }
    recorder.startEngine = { throw Gone() }
    engine.stop()
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    let error = #expect(throws: EngineRecorder.Incomplete.self) { try recorder.stop() }
    #expect(error?.reason == "the headset went away")
  }

  @Test func anUnwritableFileIsAnError() throws {
    let (engine, player) = try offlineEngine()
    let recorder = EngineRecorder(settings: .localTranscription, engine: engine, source: player)
    #expect(throws: (any Error).self) {
      try recorder.start(to: URL(fileURLWithPath: "/nonexistent-folder/out.wav"))
    }
  }
}
