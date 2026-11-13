import Foundation
@testable import SegueCore

/// Time only moves when someone sleeps. Hooks run once their time has passed.
final class FakeClock: EngineClock, @unchecked Sendable {
    private var time = 0.0
    private var hooks: [(at: Double, action: () async -> Void)] = []

    func now() -> Double { time }

    func at(_ t: Double, _ action: @escaping () async -> Void) {
        hooks.append((t, action))
        hooks.sort { $0.at < $1.at }
    }

    func advance(_ seconds: Double) { time += seconds }

    func sleep(_ seconds: Double) async {
        time += seconds
        while let first = hooks.first, first.at <= time {
            hooks.removeFirst()
            await first.action()
        }
    }
}

final class FakeMusic: MusicControlling, @unchecked Sendable {
    var running = true
    var state = PlayerState.playing
    var key: String? = "track-1"
    var vol = 80
    var nextNeverStarts = false
    var log: [String] = []
    private var counter = 1

    var isRunning: Bool { running }
    func playerState() -> PlayerState { state }
    func trackKey() -> String? { key }
    func trackTitle() -> (name: String, artist: String)? { key.map { ($0, "Artist") } }
    /// The next N volume reads fail, as when Music doesn't answer in time.
    var failVolumeReads = 0
    func volume() -> Int? {
        if failVolumeReads > 0 { failVolumeReads -= 1; return nil }
        return vol
    }
    func setVolume(_ v: Int) { vol = v; log.append("vol:\(v)") }
    func nextTrack() {
        log.append("next")
        if nextNeverStarts { state = .stopped; return }
        counter += 1
        key = "track-\(counter)"
    }
    func play() { log.append("play"); state = .playing }
    func pause() { log.append("pause"); state = .paused }

    /// Volumes written, in order, split at the first "next".
    var volumesBeforeNext: [Int] { volumes(log.prefix { $0 != "next" }) }
    var volumesAfterNext: [Int] { volumes(log.drop { $0 != "next" }) }
    var nextCount: Int { log.filter { $0 == "next" }.count }
    private func volumes(_ entries: some Sequence<String>) -> [Int] {
        entries.compactMap { $0.hasPrefix("vol:") ? Int($0.dropFirst(4)) : nil }
    }
}

struct FakeEQError: Error {}

final class FakeEQ: EqualizerControlling, @unchecked Sendable {
    var available = true
    var current = EQSnapshot(enabled: true, preset: "Flat", bands: [Int](repeating: 0, count: 10))
    var failAfterSetBandsCalls: Int?
    var setBandsCalls = 0
    var restoreCalls = 0
    /// Mirrors the real controller: after a failed call its cached controls are gone,
    /// and nothing works until prepare() finds them again.
    var stale = false

    func prepare() -> Bool {
        if available { stale = false }
        return available
    }
    func snapshot() throws -> EQSnapshot { current }
    func setEnabled(_ on: Bool) throws { current.enabled = on }
    func setBands(_ values: [Int: Int]) throws {
        setBandsCalls += 1
        if let limit = failAfterSetBandsCalls, setBandsCalls >= limit { stale = true }
        if stale { throw FakeEQError() }
        for (band, value) in values { current.bands[band] = value }
        // Music relabels any preset as Manual once a slider moves.
        current.preset = "Manual"
    }
    func restore(_ s: EQSnapshot) throws {
        restoreCalls += 1
        if stale || !available { throw FakeEQError() }
        current = s
    }
}
