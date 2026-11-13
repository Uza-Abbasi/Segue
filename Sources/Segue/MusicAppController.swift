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
final class MusicAppController: MusicControlling, @unchecked Sendable {
    static let bundleID = "com.apple.Music"
    private static let playing: AEKeyword = 0x6B50_5350   // 'kPSP'
    private static let paused: AEKeyword = 0x6B50_5370    // 'kPSp'

    private let lock = NSLock()
    private var cached: SBApplication?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Nil unless Music is already running, so a call can never launch it.
    private var app: MusicApplication? {
        guard isRunning else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if cached == nil { cached = SBApplication(bundleIdentifier: Self.bundleID) }
        return cached
    }

    /// Whether macOS lets Segue control Music. Nil while Music isn't running.
    /// With `prompt`, macOS asks the user the first time; that call can block, so keep it off the main thread.
    func automationAllowed(prompt: Bool) -> Bool? {
        guard isRunning else { return nil }
        var target = AEAddressDesc()
        let id = Array(Self.bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        if status == OSStatus(procNotFound) { return nil }
        // -1744: the user hasn't been asked yet. Treat it as not yet refused.
        return status == noErr || status == -1744
    }

    func playerState() -> PlayerState {
        switch app?.playerState {
        case Self.playing: return .playing
        case Self.paused: return .paused
        default: return .stopped
        }
    }

    func trackTitle() -> (name: String, artist: String)? {
        guard let track = app?.currentTrack, let name = track.name, !name.isEmpty else { return nil }
        return (name, track.artist ?? "")
    }

    func trackKey() -> String? {
        guard let track = app?.currentTrack, let name = track.name, !name.isEmpty else { return nil }
        return "\(track.persistentID ?? "")|\(name)|\(track.artist ?? "")|\(Int(track.duration ?? 0))"
    }

    func volume() -> Int { app?.soundVolume ?? 0 }
    func setVolume(_ v: Int) { app?.setSoundVolume?(min(max(v, 0), 100)) }
    func nextTrack() { app?.nextTrack?() }
    func pause() { app?.pause?() }
    func play() {
        guard let app, playerState() != .playing else { return }
        app.playpause?()
    }
}
