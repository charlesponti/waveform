import AVFoundation
import Foundation

/// What a recording is written as, and what is drawn from it while it happens.
///
/// The two apps want different things from the same engine. Thames streams speech to a server and
/// draws a spectrum orb, so it records 24 kHz mono AAC and pays for an FFT per hop. Ponte transcribes
/// on the device and draws a plain orb, so it records the 16 kHz mono WAV its engines read and needs
/// only loudness columns. Both are the same recorder with different settings.
public struct CaptureSettings: Sendable {
  public enum FileFormat: Sendable {
    /// Linear PCM, 16-bit, little endian — what whisper.cpp and Parakeet read.
    case wave
    /// MPEG-4 AAC, what a server is usually sent.
    case aac
  }

  public var sampleRate: Double
  public var fileFormat: FileFormat
  public var channels: Int
  /// Columns (loudness) a second. The plain orb is drawn from these.
  public var columnsPerSecond: Double
  /// Bands per spectrum frame, or nil for none at all: a spectrum costs an FFT per hop, and only the
  /// spectrum orb needs it.
  public var spectrumBands: Int?
  /// How long a column's `level` takes to fall by about 63% when the sound stops.
  public var releaseSeconds: Double

  public init(
    sampleRate: Double, fileFormat: FileFormat, channels: Int = 1,
    columnsPerSecond: Double = 120, spectrumBands: Int? = nil, releaseSeconds: Double = 0.15
  ) {
    precondition(sampleRate > 0 && columnsPerSecond > 0 && columnsPerSecond <= sampleRate)
    self.sampleRate = sampleRate
    self.fileFormat = fileFormat
    self.channels = channels
    self.columnsPerSecond = columnsPerSecond
    self.spectrumBands = spectrumBands
    self.releaseSeconds = releaseSeconds
  }

  /// Thames: speech streamed to a server, drawn as a spectrum.
  public static let streamingSpeech = CaptureSettings(
    sampleRate: 24_000, fileFormat: .aac, spectrumBands: 24)

  /// Ponte: speech transcribed on the device, drawn as a plain orb.
  public static let localTranscription = CaptureSettings(
    sampleRate: 16_000, fileFormat: .wave, spectrumBands: nil)

  /// Settings for the file itself, as `AVAudioFile` wants them.
  public var fileSettings: [String: Any] {
    switch fileFormat {
    case .wave:
      return [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    case .aac:
      return [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]
    }
  }

  /// The file extension the format implies.
  public var fileExtension: String {
    switch fileFormat {
    case .wave: return "wav"
    case .aac: return "m4a"
    }
  }
}
