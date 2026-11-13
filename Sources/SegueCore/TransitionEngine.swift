import Foundation

/// Runs DJ skips against Music and its Equalizer, and puts both back afterwards.
public actor TransitionEngine {
    public static let tick = 1.0 / 30.0
    public static let nextTrackTimeout = 5.0
    /// A skip this soon after a transition means the user is hunting for a song.
    public static let searchWindow = 3.0
    /// Seconds without a skip before DJ skips resume.
    public static let searchRelease = 10.0

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
    private var saved = StateSnapshot(volume: 0, eq: nil)
    private var interrupt: Interrupt?
    private var volumeManaged = true
    private var recentVolumes: [Int] = []
    private var isSkip = true

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
    public func recoverIfNeeded() {
        guard !isRunning, music.isRunning, let snapshot = store.load() else { return }
        music.setVolume(snapshot.volume)
        if let eqSnapshot = snapshot.eq, eq.prepare() { try? eq.restore(eqSnapshot) }
        store.clear()
    }

    public func togglePause(settings: TransitionSettings) async {
        guard music.isRunning else { return }
        if isRunning {
            interrupt = .cancelAndPause
            return
        }
        let state = music.playerState()
        guard settings.fadeOnPause, state != .stopped else {
            if state == .playing { music.pause() } else { music.play() }
            return
        }

        // Pause fades are too short to be worth a snapshot on disk.
        begin(StateSnapshot(volume: music.volume(), eq: nil), isSkip: false)
        if state == .playing {
            await fadeVolume(from: saved.volume, to: 0, over: TransitionSettings.pauseFade)
            if let stop = stopReason() { return handle(stop) }
            music.pause()
        } else {
            writeVolume(0)
            music.play()
            await fadeVolume(from: 0, to: saved.volume, over: TransitionSettings.pauseFade)
            if let stop = stopReason() { return handle(stop) }
        }
        finish()
    }

    public func djSkip(settings: TransitionSettings) async {
        guard music.isRunning else { return }
        if isRunning {
            interrupt = .skip
            return
        }
        guard music.playerState() == .playing else {
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
        if settings.eqEffects, eq.prepare() { eqSnapshot = try? eq.snapshot() }
        begin(StateSnapshot(volume: music.volume(), eq: eqSnapshot))
        store.save(saved)

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
            writeVolume(FadeCurve.volume(start: saved.volume, recipe: recipe, progress: progress))
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
        lastSkipAt = clock.now()
        while !(music.playerState() == .playing && music.trackKey() != startKey),
              clock.now() - lastSkipAt < Self.nextTrackTimeout {
            await clock.sleep(Self.tick)
            if let stop = stopReason() { return handle(stop) }
        }

        restoreEQ()
        await fadeVolume(from: 0, to: saved.volume, over: settings.fadeIn)
        if let stop = stopReason() { return handle(stop) }
        finish()
    }

    // MARK: - Transition plumbing

    private func begin(_ snapshot: StateSnapshot, isSkip: Bool = true) {
        saved = snapshot
        self.isSkip = isSkip
        interrupt = nil
        volumeManaged = true
        recentVolumes = [snapshot.volume]
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
            // A second press means the user is hunting for a song: stop the show and skip.
            plainSkip()
            searchMode = true
            finish()
        case .interrupt(.cancelAndPause):
            finish()
            music.pause()
        }
    }

    /// Sets the volume unless the user has taken it over.
    private func writeVolume(_ v: Int) {
        guard volumeManaged else { return }
        let actual = music.volume()
        // Music can report a write a moment late, so compare against the last few.
        if !recentVolumes.contains(where: { abs($0 - actual) <= 1 }) {
            volumeManaged = false
            return
        }
        music.setVolume(v)
        recentVolumes.append(v)
        if recentVolumes.count > 3 { recentVolumes.removeFirst() }
    }

    /// Stops early, leaving the volume wherever it is, if the transition must stop.
    private func fadeVolume(from: Int, to: Int, over seconds: Double) async {
        let start = clock.now()
        while seconds > 0 {
            if stopReason() != nil { return }
            let elapsed = clock.now() - start
            if elapsed >= seconds { break }
            let level = sin(elapsed / seconds * .pi / 2)
            writeVolume(Int((Double(from) + Double(to - from) * level).rounded()))
            await clock.sleep(Self.tick)
        }
    }

    private func restoreEQ() {
        if let eqSnapshot = saved.eq { try? eq.restore(eqSnapshot) }
        saved.eq = nil
    }

    /// Puts back whatever is still changed and ends the transition.
    private func finish() {
        restoreEQ()
        writeVolume(saved.volume)
        store.clear()
        interrupt = nil
        if isSkip { lastTransitionEnd = clock.now() }
        isRunning = false
    }
}
