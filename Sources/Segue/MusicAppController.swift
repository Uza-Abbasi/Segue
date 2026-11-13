import AppKit
import ScriptingBridge
import SegueCore

// The slice of Music's scripting interface Segue uses, resolved at run time by ScriptingBridge.
@objc private protocol MusicTrack {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var persistentID: String { get }
    @objc optional var duration: Double { get }
}

@objc private protocol MusicApplication {
    @objc optional var playerState: AEKeyword { get }
    @objc optional var soundVolume: Int { get }
    @objc optional func setSoundVolume(_ volume: Int)
    @objc optional var currentTrack: MusicTrack { get }
    @objc optional func nextTrack()
    @objc optional func playpause()
    @objc optional func pause()
}

extension SBObject: MusicTrack {}
extension SBApplication: MusicApplication {}

/// Controls the Music app through Apple Events. Never launches Music.
/// Calls block until Music answers, so keep them off the main thread.
final class MusicAppController: MusicControlling, @unchecked Sendable {
    static let bundleID = "com.apple.Music"
    private static let playing: AEKeyword = 0x6B50_5350   // 'kPSP'
    private static let paused: AEKeyword = 0x6B50_5370    // 'kPSp'
    /// In ticks (1/60 s). The default is about two minutes, which would hang Segue if Music stalls.
    private static let eventTimeout = 120

    /// One event at a time: the engine and the panel's refresh share this object.
    private let lock = NSRecursiveLock()
    private var cached: SBApplication?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Runs `body` against Music. Nil if Music isn't already running, so a call can never launch it.
    private func withApp<T>(_ body: (MusicApplication) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return nil }
        if cached == nil {
            cached = SBApplication(bundleIdentifier: Self.bundleID)
            cached?.timeout = Self.eventTimeout
        }
        return cached.flatMap(body)
    }

    /// macOS's answer on whether Segue may control Music: `noErr` when allowed, -1743 when
    /// refused, -1744 when the user hasn't been asked. Nil while Music isn't running.
    /// With `prompt`, macOS asks the first time, and the call blocks until the user answers.
    func automationStatus(prompt: Bool) -> OSStatus? {
        guard isRunning else { return nil }
        var target = AEAddressDesc()
        let id = Array(Self.bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        return status == OSStatus(procNotFound) ? nil : status
    }

    func playerState() -> PlayerState {
        switch withApp({ $0.playerState }) {
        case Self.playing: return .playing
        case Self.paused: return .paused
        default: return .stopped
        }
    }

    func trackTitle() -> (name: String, artist: String)? {
        withApp { app in
            guard let track = app.currentTrack, let name = track.name, !name.isEmpty else { return nil }
            return (name, track.artist ?? "")
        }
    }

    func trackKey() -> String? {
        withApp { app in
            guard let track = app.currentTrack, let name = track.name, !name.isEmpty else { return nil }
            return "\(track.persistentID ?? "")|\(name)|\(track.artist ?? "")|\(Int(track.duration ?? 0))"
        }
    }

    func volume() -> Int? { withApp { $0.soundVolume } }
    func setVolume(_ v: Int) { _ = withApp { $0.setSoundVolume?(min(max(v, 0), 100)) } }
    func nextTrack() { _ = withApp { $0.nextTrack?() } }
    func pause() { _ = withApp { $0.pause?() } }
    func play() {
        _ = withApp { app -> Void? in
            guard app.playerState != Self.playing else { return nil }
            return app.playpause?()
        }
    }
}
