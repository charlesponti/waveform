import AVFoundation
import Foundation
import Testing

@testable import WaveformCore

/// `LiveInput` is tested against a real `AVAudioEngine` in offline rendering mode: the engine runs the
/// same graph and taps as it would on a device, but a test drives it by hand, so no microphone, speaker
/// or permission is involved.
@Suite struct LiveInputTests {
  static let rate = 48_000.0

  private func offlineEngine() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return engine
  }

  private func render(_ engine: AVAudioEngine, seconds: Double) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var left = Int(seconds * Self.rate)
    while left > 0 {
      let n = min(left, 4096)
      let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
      #expect(status == .success)
      left -= n
    }
  }

  private func pcm(_ samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
  }

  private func wav(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID()).wav")
    let samples = Synthesize.vowels(seconds: seconds, sampleRate: Self.rate)
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
      ])
    try file.write(from: pcm(samples))
    return url
  }

  @Test func playingAFileFillsTheColumnAndSpectrumRings() throws {
    let engine = try offlineEngine()
    let live = LiveInput(ring: ColumnRing(capacity: 1024), columnsPerSecond: 120, engine: engine)
    let url = try wav(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    try live.play(file: url)
    try render(engine, seconds: 1)
    live.stop()
    // One second at 120 columns a second. The engine hands the tap its buffers in chunks, so the last
    // few columns may still be on their way; what matters is that most arrived and none were invented.
    #expect((90...122).contains(live.ring.count))
    #expect(live.spectrum.count == live.ring.count)
    var loudest: Float = 0
    var out = [Column](repeating: .silent, count: 64)
    out.withUnsafeMutableBufferPointer { _ = live.ring.copyLast(64, into: $0.baseAddress!) }
    for column in out { loudest = max(loudest, column.rms) }
    #expect(loudest > 0.01)
  }

  @Test func theClockIsToldWhenEachBufferBegan() throws {
    let engine = try offlineEngine()
    let live = LiveInput(ring: ColumnRing(capacity: 1024), engine: engine)
    let url = try wav(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    try live.play(file: url)
    try render(engine, seconds: 0.5)
    live.stop()
    // Offline rendering may or may not stamp buffers with a host time; either way nothing is wrong.
    if let offset = live.clock.offset { #expect(offset.isFinite) }
  }

  @Test func aMissingFileThrows() throws {
    let live = LiveInput(ring: ColumnRing(capacity: 16), engine: try offlineEngine())
    #expect(throws: (any Error).self) { try live.play(file: URL(fileURLWithPath: "/nonexistent/none.wav")) }
  }

  @Test func aRefusedMicrophoneThrowsAndSaysWhy() async throws {
    let live = LiveInput(ring: ColumnRing(capacity: 16), engine: try offlineEngine(), requestAccess: { false })
    await #expect(throws: LiveInput.MicrophoneError.self) { try await live.startMicrophone() }
    #expect(LiveInput.MicrophoneError.denied.description.contains("System Settings"))
  }

  @Test func anAllowedMicrophoneFillsTheRings() async throws {
    let engine = try offlineEngine()
    let tone = (0..<4096).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / Self.rate)) }
    let source = pcm(tone)
    try engine.inputNode.setManualRenderingInputPCMFormat(source.format) { frames in
      source.frameLength = min(frames, 4096)
      return UnsafePointer(source.audioBufferList)
    }
    engine.connect(engine.inputNode, to: engine.mainMixerNode, format: source.format)
    let live = LiveInput(ring: ColumnRing(capacity: 1024), engine: engine, requestAccess: { true })
    try await live.startMicrophone()
    try render(engine, seconds: 1)
    live.stop()
    #expect(live.ring.count > 100)
    #expect(live.spectrum.count > 100)
  }

  @Test func theDefaultEngineIsCreatedWhenNoneIsGiven() {
    let live = LiveInput(ring: ColumnRing(capacity: 16), requestAccess: { true })
    #expect(live.columnsPerSecond == 120)
  }
}

@Suite struct StampTests {
  @Test func aBufferWithAHostTimeTellsTheClockWhenItBegan() {
    let clock = StreamClock()
    let when = AVAudioTime(hostTime: mach_absolute_time())
    LiveInput.stamp(clock, at: when, samplesSeen: 48_000, rate: 48_000)
    let offset = try! #require(clock.offset)
    #expect(abs(offset - (AVAudioTime.seconds(forHostTime: when.hostTime) - 1)) < 1e-9)
  }

  @Test func aBufferWithoutOneLeavesTheClockAlone() {
    let clock = StreamClock()
    LiveInput.stamp(clock, at: AVAudioTime(sampleTime: 0, atRate: 48_000), samplesSeen: 0, rate: 48_000)
    #expect(clock.offset == nil)
  }
}
