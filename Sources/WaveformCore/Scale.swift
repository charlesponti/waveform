import Foundation

/// How a sample value becomes a height. Linear shows the signal as it is; decibels show it as it is
/// heard, so quiet speech is still visible next to a loud word.
public enum Scale: Sendable {
  case linear
  /// Decibels relative to full scale, with `floor` (for example -60) drawn as nothing and 0 as full height.
  case decibels(floor: Float)

  /// Maps a sample in -1...1 to -1...1, keeping its sign.
  public func height(_ value: Float) -> Float {
    switch self {
    case .linear:
      return max(-1, min(1, value))
    case .decibels(let floor):
      let magnitude = abs(value)
      guard magnitude > 0 else { return 0 }
      let db = 20 * log10(magnitude)
      let unit = max(0, min(1, (db - floor) / -floor))
      return value < 0 ? -unit : unit
    }
  }
}
