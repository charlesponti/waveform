import AVFoundation
import Foundation
import Testing
import WaveformCore

@testable import WaveformCapture

/// The seam, tested from the outside: anything that can hand over buffers can feed the recorder.
///
/// This is what makes the device picker buildable at all. The engine path is covered by `EngineRecorderTests` with a
/// real offline engine; these cover the promise the seam makes — a source that is not an `AVAudioEngine` records
/// correctly, a change of format part way through is followed rather than fatal, and a source that cannot open throws
/// instead of recording silence.
@Suite struct AudioSourceSeamTests {

  /// A source with no hardware behind it, so the test says what the seam does rather than what this Mac's
  /// microphone happened to do.
  final class FakeSource: AudioSource {
    let format: AVAudioFormat
    var delivered: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var started = false
    var stopped = false
    var failure: Error?
    var formatChanges = 0
    private var current: AVAudioFormat

    init(rate: Double, failure: Error? = nil) {
      self.format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
      self.current = format
      self.failure = failure
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
      if let failure { throw failure }
      started = true
      delivered = onBuffer
    }

    func stop() { stopped = true }

    /// Emit `count` frames of a sine, in the current format.
    func emit(frames count: AVAudioFrameCount, rate: Double? = nil) throws {
      if let rate, rate != current.sampleRate {
        current = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        formatChanges += 1
      }
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: current, frameCapacity: count))
      buffer.frameLength = count
      let channel = try #require(buffer.floatChannelData?[0])
      for index in 0..<Int(count) {
        channel[index] = 0.25 * sinf(2 * .pi * 440 * Float(index) / Float(current.sampleRate))
      }
      delivered?(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }
  }

  struct Scratch: ~Copyable {
    let url: URL
    init() {
      url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("waveform-seam-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  @Test func aSourceThatIsNotTheEngineRecordsTheFile() throws {
    let scratch = Scratch()
    let out = scratch.file("seam.wav")
    // 48 kHz in, 16 kHz out: 48 000 frames become 16 000, i.e. one second of the file's own rate.
    let source = FakeSource(rate: 48_000)
    let recorder = EngineRecorder(settings: .localTranscription, audioSource: source)

    try recorder.start(to: out)
    #expect(source.started, "start reaches the source")

    for _ in 0..<10 { try source.emit(frames: 4_800) }
    let milliseconds = try recorder.stop()

    #expect(source.stopped, "stop reaches the source")
    #expect(abs(milliseconds - 1_000) < 30, "48 000 frames at 48 kHz is one second — got \(milliseconds) ms")

    let written = try AVAudioFile(forReading: out)
    // Not exactly 16 000: a converter holds a few frames of priming, and the tail of the last buffer is padding.
    #expect(abs(Double(written.length) - 16_000) < 700,
            "the file holds the resampled length, not the source's — got \(written.length)")
    #expect(written.processingFormat.sampleRate == 16_000)
    #expect(written.processingFormat.channelCount == 1)
  }

  @Test func aFormatChangePartWayThroughIsFollowed() throws {
    let scratch = Scratch()
    let out = scratch.file("change.wav")
    let source = FakeSource(rate: 48_000)
    let recorder = EngineRecorder(settings: .localTranscription, audioSource: source)
    try recorder.start(to: out)

    for _ in 0..<5 { try source.emit(frames: 4_800) }              // 0.5 s at 48 kHz
    for _ in 0..<5 { try source.emit(frames: 4_800, rate: 24_000) } // 1.0 s at 24 kHz — half as many frames a second
    let milliseconds = try recorder.stop()

    #expect(source.formatChanges == 1)
    #expect(abs(milliseconds - 1_500) < 80, "both halves count — got \(milliseconds) ms")
    let written = try AVAudioFile(forReading: out)
    #expect(abs(Double(written.length) - 24_000) < 900, "1.5 s at 16 kHz — got \(written.length)")
  }

  @Test func aSourceThatCannotOpenThrowsInsteadOfRecordingSilence() throws {
    struct DeviceGone: LocalizedError { var errorDescription: String? { "the device went away" } }
    let scratch = Scratch()
    let source = FakeSource(rate: 48_000, failure: DeviceGone())
    let recorder = EngineRecorder(settings: .localTranscription, audioSource: source)

    #expect(throws: DeviceGone.self) {
      try recorder.start(to: scratch.file("never.wav"))
    }
    #expect(!source.started, "the source refused, so it never started")
  }

  @Test func theColumnsAreBuiltFromASourceThatIsNotTheEngine() throws {
    let scratch = Scratch()
    let source = FakeSource(rate: 48_000)
    let recorder = EngineRecorder(settings: .localTranscription, audioSource: source)
    try recorder.start(to: scratch.file("columns.wav"))
    for _ in 0..<20 { try source.emit(frames: 4_800) }
    _ = try recorder.stop()

    // The orb's picture comes from the same buffers the file is written from.
    var newest = Column.silent
    let pulled = withUnsafeMutablePointer(to: &newest) { recorder.columns.copyLast(1, into: $0) }
    #expect(pulled == 1, "the column ring received something")
  }

  @Test func choosingASourceWithoutAPinKeepsTheEnginePath() {
    // The promise to the app: no pin means no change at all in how it records.
    let unpinned = AudioSourceChoice.make(settings: .localTranscription, deviceUID: nil)
    #expect(unpinned is EngineSource)

    let empty = AudioSourceChoice.make(settings: .localTranscription, deviceUID: "")
    #expect(empty is EngineSource)

    let pinned = AudioSourceChoice.make(settings: .localTranscription, deviceUID: "BuiltInMicrophoneDevice")
    #expect(pinned is CaptureSource)
  }
}
