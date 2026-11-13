public enum FadeShape: CaseIterable, Sendable {
    case earlyDrop, steady, lateDrop
}

/// Which part of the 10-band equalizer a transition cuts.
/// Bands are indexed 0...9 = 32, 64, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz.
public enum EQFocus: CaseIterable, Sendable {
    case none, lows, mids, highs, lowsAndHighs

    /// Band index → share of the recipe's depth applied to that band.
    public var bandWeights: [Int: Double] {
        switch self {
        case .none: return [:]
        case .lows: return [0: 1, 1: 1, 2: 1, 3: 1, 4: 0.5]
        case .mids: return [3: 0.5, 4: 1, 5: 1, 6: 1, 7: 0.5]
        case .highs: return [6: 0.5, 7: 1, 8: 1, 9: 1]
        case .lowsAndHighs:
            return EQFocus.lows.bandWeights.merging(EQFocus.highs.bandWeights) { max($0, $1) }
        }
    }
}

public struct Recipe: Equatable, Sendable {
    /// Seconds.
    public var length: Double
    /// Share of the starting volume the fade stops at before the skip.
    public var fadeTarget: Double
    public var shape: FadeShape
    public var focus: EQFocus
    /// Hundredths of a dB, -1200...-600.
    public var depth: Int

    public init(length: Double, fadeTarget: Double, shape: FadeShape, focus: EQFocus, depth: Int) {
        self.length = length
        self.fadeTarget = fadeTarget
        self.shape = shape
        self.focus = focus
        self.depth = depth
    }
}

public struct TransitionSettings: Equatable, Sendable {
    public var minLength = 3.0
    public var maxLength = 8.0
    public var variation = true
    public var eqEffects = true
    public var fadeIn = 1.5
    public var fadeOnPause = true
    public static let pauseFade = 0.6

    public init() {}
}
