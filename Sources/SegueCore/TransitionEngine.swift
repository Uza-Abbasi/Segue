import Foundation

/// Runs DJ skips against Music and its Equalizer, and puts both back afterwards.
public actor TransitionEngine {
    public static let tick = 1.0 / 30.0
    public static let nextTrackTimeout = 5.0

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

    /// State of the transition in flight.
    private var saved = StateSnapshot(volume: 0, eq: nil)
    private var eqOK = false

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

    public func djSkip(settings: TransitionSettings) async {
        guard music.isRunning else { return }
        guard music.playerState() == .playing else {
            music.nextTrack()
            return
        }

        eqOK = settings.eqEffects && eq.prepare()
        var eqSnapshot: EQSnapshot?
        if eqOK {
            eqSnapshot = try? eq.snapshot()
            eqOK = eqSnapshot != nil
        }
        saved = StateSnapshot(volume: music.volume(), eq: eqSnapshot)
        store.save(saved)

        let recipe = picker.next(settings: settings, eqAvailable: eqOK, using: &rng)
        lastRecipe = recipe
        isRunning = true
        let startKey = music.trackKey()

        if recipe.focus != .none, let eqSnapshot, !eqSnapshot.enabled {
            try? eq.setEnabled(true)
        }

        // Fade out and sweep.
        let start = clock.now()
        while true {
            let elapsed = clock.now() - start
            if elapsed >= recipe.length { break }
            let progress = elapsed / recipe.length
            music.setVolume(FadeCurve.volume(start: saved.volume, recipe: recipe, progress: progress))
            if let eqSnapshot, recipe.focus != .none {
                try? eq.setBands(FadeCurve.bands(original: eqSnapshot.bands, recipe: recipe, progress: progress))
            }
            await clock.sleep(Self.tick)
        }

        // Skip, and wait for the next song to actually start.
        music.setVolume(0)
        music.nextTrack()
        let skippedAt = clock.now()
        while !(music.playerState() == .playing && music.trackKey() != startKey),
              clock.now() - skippedAt < Self.nextTrackTimeout {
            await clock.sleep(Self.tick)
        }

        restoreEQ()

        // Fade the next song in.
        let fadeStart = clock.now()
        while settings.fadeIn > 0 {
            let elapsed = clock.now() - fadeStart
            if elapsed >= settings.fadeIn { break }
            let level = sin(elapsed / settings.fadeIn * .pi / 2)
            music.setVolume(Int((Double(saved.volume) * level).rounded()))
            await clock.sleep(Self.tick)
        }

        finish(restoreVolume: true)
    }

    private func restoreEQ() {
        if let eqSnapshot = saved.eq { try? eq.restore(eqSnapshot) }
        saved.eq = nil
    }

    /// Puts back whatever is still changed and ends the transition.
    private func finish(restoreVolume: Bool) {
        restoreEQ()
        if restoreVolume { music.setVolume(saved.volume) }
        store.clear()
        isRunning = false
    }
}
