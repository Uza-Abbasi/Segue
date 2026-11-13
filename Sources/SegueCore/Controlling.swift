import Foundation

public enum PlayerState: Sendable {
    case playing, paused, stopped
}

/// The Equalizer window's state. `bands` holds 10 values in hundredths of a dB.
public struct EQSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var preset: String
    public var bands: [Int]

    public init(enabled: Bool, preset: String, bands: [Int]) {
        self.enabled = enabled
        self.preset = preset
        self.bands = bands
    }
}

/// What a transition changes and must put back.
public struct StateSnapshot: Codable, Equatable, Sendable {
    public var volume: Int
    public var eq: EQSnapshot?

    public init(volume: Int, eq: EQSnapshot?) {
        self.volume = volume
        self.eq = eq
    }
}

public protocol MusicControlling: Sendable {
    var isRunning: Bool { get }
    func playerState() -> PlayerState
    /// Stable identity of the current track, nil if there is none.
    func trackKey() -> String?
    func trackTitle() -> (name: String, artist: String)?
    /// 0...100
    func volume() -> Int
    func setVolume(_ v: Int)
    func nextTrack()
    func play()
    func pause()
}

public protocol EqualizerControlling: Sendable {
    /// Makes sure the Equalizer's controls are reachable. False if they are not.
    func prepare() -> Bool
    func snapshot() throws -> EQSnapshot
    func setEnabled(_ on: Bool) throws
    /// Band index (0...9) → hundredths of a dB.
    func setBands(_ values: [Int: Int]) throws
    func restore(_ s: EQSnapshot) throws
}

public protocol EngineClock: Sendable {
    func now() -> Double
    func sleep(_ seconds: Double) async
}

public struct SystemClock: EngineClock {
    public init() {}
    public func now() -> Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}
