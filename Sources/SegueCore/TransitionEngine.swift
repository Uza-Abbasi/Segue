import Foundation

/// Runs DJ skips against Music and its Equalizer, and puts both back afterwards.
public actor TransitionEngine {
    public static let tick = 1.0 / 30.0
    public static let nextTrackTimeout = 5.0
    /// A skip this soon after a transition means the user is hunting for a song.
    public static let searchWindow = 3.0
    /// Seconds without a skip before DJ skips resume.
    public static let searchRelease = 10.0
    /// Music animates a restored preset into place, and its Equalizer window shows the old
    /// preset name and slider values until it is done. Measured at about 0.6 s.
    public static let eqSettleTime = 1.5

    private enum Interrupt { case skip, cancelAndPause }
    private enum Stop { case interrupt(Interrupt), trackChanged, musicGone }

    private let music: MusicControlling
    private let eq: EqualizerControlling
    private let store: SnapshotStore
    private let clock: EngineClock
    private var rng: any RandomNumberGenerator
    private var picker = RecipePicker()
    private var runningHandler: (@Sendable (Bool) -> Void)?

    public private(set) var lastRecipe: Recipe?
    public private(set) var isRunning = false {
        didSet { if isRunning != oldValue { runningHandler?(isRunning) } }
    }

    private var searchMode = false
    private var lastSkipAt = -Double.infinity
    private var lastTransitionEnd = -Double.infinity

    /// State of the transition in flight.
    private var savedVolume = 0
    private var savedEQ: EQSnapshot?
    private var interrupt: Interrupt?
    private var isSkip = true
    private var didSkip = false
    private var volumeManaged = true
    private var volumeMismatches = 0
    private var recentVolumes: [Int] = []
    /// The EQ state last put back, and when. Trusted over the window until it has settled.
    private var lastRestore: (eq: EQSnapshot, at: Double)?

    public init(music: MusicControlling, eq: EqualizerControlling, store: SnapshotStore,
                clock: EngineClock, rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.music = music
        self.eq = eq
        self.store = store
        self.clock = clock
        self.rng = rng
    }

    public func setRunningHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        runningHandler = handler
    }

    /// Restores volume and EQ from a snapshot left behind by a transition that never finished.
    /// Whatever can't be put back yet stays on disk for the next attempt.
    public func recoverIfNeeded() {
        guard !isRunning, music.isRunning, let snapshot = store.load() else { return }
        if let volume = snapshot.volume { music.setVolume(volume) }
        if let eqSnapshot = snapshot.eq, !restore(eqSnapshot) {
            store.save(StateSnapshot(volume: nil, eq: eqSnapshot))
        } else {
            store.clear()
        }
    }

    public func djSkip(settings: TransitionSettings) async {
        guard music.isRunning else { return }
        if isRunning {
            interrupt = .skip
            return
        }
        recoverIfNeeded()
        guard music.playerState() == .playing, let startVolume = music.volume() else {
            music.nextTrack()
            return
        }
        let now = clock.now()
        if searchMode, now - lastSkipAt < Self.searchRelease {
            plainSkip()
            return
        }
        if now - lastTransitionEnd < Self.searchWindow {
            searchMode = true
            plainSkip()
            return
        }
        searchMode = false

        var eqSnapshot: EQSnapshot?
        if settings.eqEffects, eq.prepare() { eqSnapshot = settlingEQ() ?? (try? eq.snapshot()) }
        begin(volume: startVolume, eq: eqSnapshot, isSkip: true)
        store.save(StateSnapshot(volume: startVolume, eq: eqSnapshot))

        let recipe = picker.next(settings: settings, eqAvailable: eqSnapshot != nil, using: &rng)
        lastRecipe = recipe
        let startKey = music.trackKey()

        var sweeping = recipe.focus != .none && eqSnapshot != nil
        if sweeping, let eqSnapshot, !eqSnapshot.enabled {
            do { try eq.setEnabled(true) } catch { sweeping = false }
        }

        // Fade out and sweep.
        let start = clock.now()
        while true {
            if let stop = stopReason(trackShouldBe: startKey) { return handle(stop) }
            let elapsed = clock.now() - start
            if elapsed >= recipe.length { break }
            let progress = elapsed / recipe.length
            writeVolume(FadeCurve.volume(start: savedVolume, recipe: recipe, progress: progress))
            if sweeping, let eqSnapshot {
                do {
                    try eq.setBands(FadeCurve.bands(original: eqSnapshot.bands, recipe: recipe, progress: progress))
                } catch {
                    sweeping = false
                }
            }
            await clock.sleep(Self.tick)
        }

        // Skip, and wait for the next song to actually start.
        writeVolume(0)
        music.nextTrack()
        didSkip = true
        lastSkipAt = clock.now()
        while !(music.playerState() == .playing && music.trackKey() != startKey),
              clock.now() - lastSkipAt < Self.nextTrackTimeout {
            await clock.sleep(Self.tick)
            if let stop = stopReason() { return handle(stop) }
        }

        // The new song comes in through the same filter the old one left by, opening up as it
        // fades in. finish() then puts the preset and on/off state back.
        if !sweeping { restoreEQ() }
        await fadeVolume(from: 0, to: savedVolume, over: settings.fadeIn) { progress in
            guard sweeping, let eqSnapshot else { return }
            do {
                try self.eq.setBands(FadeCurve.bands(original: eqSnapshot.bands, recipe: recipe,
                                                     progress: 1 - progress))
            } catch {
                sweeping = false
            }
        }
        if let stop = stopReason() { return handle(stop) }
        finish()
    }

    public func togglePause(settings: TransitionSettings) async {
        guard music.isRunning else { return }
        if isRunning {
            interrupt = .cancelAndPause
            return
        }
        recoverIfNeeded()
        let state = music.playerState()
        guard settings.fadeOnPause, state != .stopped, let startVolume = music.volume() else {
            if state == .playing { music.pause() } else { music.play() }
            return
        }

        begin(volume: startVolume, eq: nil, isSkip: false)
        store.save(StateSnapshot(volume: startVolume, eq: nil))
        if state == .playing {
            await fadeVolume(from: savedVolume, to: 0, over: TransitionSettings.pauseFade)
            if let stop = stopReason() { return handle(stop) }
            music.pause()
        } else {
            writeVolume(0)
            music.play()
            await fadeVolume(from: 0, to: savedVolume, over: TransitionSettings.pauseFade)
            if let stop = stopReason() { return handle(stop) }
        }
        finish()
    }

    // MARK: - Transition plumbing

    private func begin(volume: Int, eq: EQSnapshot?, isSkip: Bool) {
        savedVolume = volume
        savedEQ = eq
        self.isSkip = isSkip
        didSkip = false
        interrupt = nil
        volumeManaged = true
        volumeMismatches = 0
        recentVolumes = [volume]
        isRunning = true
    }

    private func plainSkip() {
        music.nextTrack()
        lastSkipAt = clock.now()
    }

    /// Why the transition in flight must stop now, if it must.
    private func stopReason(trackShouldBe key: String?? = nil) -> Stop? {
        if !music.isRunning { return .musicGone }
        if let interrupt { return .interrupt(interrupt) }
        if let key, music.trackKey() != key { return .trackChanged }
        return nil
    }

    private func handle(_ stop: Stop) {
        switch stop {
        case .musicGone:
            // Nothing to talk to. The snapshot stays on disk for recoverIfNeeded().
            interrupt = nil
            isRunning = false
        case .trackChanged:
            finish()
        case .interrupt(.skip):
            plainSkip()
            if isSkip {
                // A second press means the user is hunting for a song.
                didSkip = true
                searchMode = true
            }
            finish()
        case .interrupt(.cancelAndPause):
            // Pause before the volume comes back, so there is no burst of full volume.
            music.pause()
            finish()
        }
    }

    /// Sets the volume unless the user has taken it over.
    private func writeVolume(_ v: Int) {
        guard volumeManaged else { return }
        // A read that fails says nothing about the user, so it never costs us control.
        // Music can report a write a moment late, so compare against the last few.
        if let actual = music.volume(), !recentVolumes.contains(where: { abs($0 - actual) <= 1 }) {
            // Hold this write; if it still differs on the next one, the user moved it.
            volumeMismatches += 1
            if volumeMismatches >= 2 { volumeManaged = false }
            return
        }
        volumeMismatches = 0
        music.setVolume(v)
        recentVolumes.append(v)
        if recentVolumes.count > 3 { recentVolumes.removeFirst() }
    }

    /// Stops early, leaving the volume wherever it is, if the transition must stop.
    /// `each` runs on every step with the fade's progress, 0 to 1.
    private func fadeVolume(from: Int, to: Int, over seconds: Double,
                            each: ((Double) -> Void)? = nil) async {
        let start = clock.now()
        while seconds > 0 {
            if stopReason() != nil { return }
            let elapsed = clock.now() - start
            if elapsed >= seconds { break }
            each?(elapsed / seconds)
            let level = sin(elapsed / seconds * .pi / 2)
            writeVolume(Int((Double(from) + Double(to - from) * level).rounded()))
            await clock.sleep(Self.tick)
        }
    }

    /// A failed call drops the controller's cached controls, so one retry goes through prepare().
    private func restore(_ snapshot: EQSnapshot) -> Bool {
        guard (try? eq.restore(snapshot)) != nil
                || (eq.prepare() && (try? eq.restore(snapshot)) != nil) else { return false }
        lastRestore = (snapshot, clock.now())
        return true
    }

    /// The state a restore is still moving the Equalizer towards, if one just happened.
    /// Reading the window now would save the swept sliders as if they were the user's own.
    private func settlingEQ() -> EQSnapshot? {
        guard let lastRestore, clock.now() - lastRestore.at < Self.eqSettleTime else { return nil }
        return lastRestore.eq
    }

    private func restoreEQ() {
        if let snapshot = savedEQ, restore(snapshot) { savedEQ = nil }
    }

    /// Puts back whatever is still changed and ends the transition.
    private func finish() {
        restoreEQ()
        writeVolume(savedVolume)
        // A held write gets one more try, so a single odd read can't leave the volume partway.
        if volumeMismatches > 0 { writeVolume(savedVolume) }
        if let unrestored = savedEQ {
            store.save(StateSnapshot(volume: nil, eq: unrestored))
        } else {
            store.clear()
        }
        interrupt = nil
        if didSkip { lastTransitionEnd = clock.now() }
        isRunning = false
    }
}
