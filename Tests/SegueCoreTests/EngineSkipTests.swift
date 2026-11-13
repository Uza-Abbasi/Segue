import Foundation
import Testing
@testable import SegueCore

struct Rig {
    let engine: TransitionEngine
    let music = FakeMusic()
    let eq = FakeEQ()
    let clock = FakeClock()
    let store = SnapshotStore(directory: tempDirectory())

    init(seed: UInt64 = 1) {
        engine = TransitionEngine(music: music, eq: eq, store: store, clock: clock,
                                  rng: SplitMix64(seed: seed))
    }
}

/// Variation off: every skip is the 5.5 s lows cut that fades to zero.
var fixedSettings: TransitionSettings {
    var s = TransitionSettings()
    s.variation = false
    return s
}

let rock = EQSnapshot(enabled: true, preset: "Rock", bands: [Int](repeating: 50, count: 10))

func isNonIncreasing(_ xs: [Int]) -> Bool { zip(xs, xs.dropFirst()).allSatisfy { $0 >= $1 } }
func isNonDecreasing(_ xs: [Int]) -> Bool { zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 } }

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Test func normalSkipOrderAndRestore() async {
    let rig = Rig()
    rig.eq.current = rock
    await rig.engine.djSkip(settings: fixedSettings)

    #expect(rig.music.nextCount == 1)
    let before = rig.music.volumesBeforeNext, after = rig.music.volumesAfterNext
    #expect(before.count > 100)
    #expect(isNonIncreasing(before))
    #expect(before.last == 0)
    #expect(isNonDecreasing(after))
    #expect(after.last == 80)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.eq.setBandsCalls > 100)
    #expect(abs(rig.clock.now() - 7.0) < 0.2)
    #expect(rig.store.load() == nil)
    #expect(await rig.engine.isRunning == false)
}

@Test func snapshotIsOnDiskDuringTransition() async {
    let rig = Rig()
    rig.eq.current = rock
    let captured = Box<StateSnapshot?>(nil)
    rig.clock.at(2.0) { captured.value = rig.store.load() }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(captured.value == StateSnapshot(volume: 80, eq: rock))
}

@Test func sweepReachesFullDepthBeforeTheSkip() async {
    let rig = Rig()
    let bands = Box<[Int]>([])
    rig.clock.at(5.45) { bands.value = rig.eq.current.bands }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(bands.value[0] < -1100)
    #expect(bands.value[9] == 0)
}

@Test func eqOffIsTurnedOnThenOffAgain() async {
    let rig = Rig()
    rig.eq.current.enabled = false
    let during = Box(false)
    rig.clock.at(2.0) { during.value = rig.eq.current.enabled }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(during.value == true)
    #expect(rig.eq.current.enabled == false)
}

@Test func notPlayingIsPlainSkip() async {
    let rig = Rig()
    rig.music.state = .paused
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.log == ["next"])
    #expect(rig.eq.setBandsCalls == 0)
    #expect(rig.clock.now() == 0)
}

@Test func musicNotRunningDoesNothing() async {
    let rig = Rig()
    rig.music.running = false
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.log.isEmpty)
}

@Test func eqUnavailableIsFadeOnly() async {
    let rig = Rig()
    rig.eq.available = false
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.setBandsCalls == 0)
    #expect(rig.eq.restoreCalls == 0)
    #expect(rig.music.nextCount == 1)
    #expect(rig.music.vol == 80)
}

@Test func eqEffectsOffIsFadeOnly() async {
    let rig = Rig()
    var s = fixedSettings
    s.eqEffects = false
    await rig.engine.djSkip(settings: s)
    #expect(rig.eq.setBandsCalls == 0)
    #expect(rig.eq.restoreCalls == 0)
    #expect(rig.music.nextCount == 1)
    #expect(rig.music.vol == 80)
}

@Test func nextTrackNeverStartsStillRestores() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.music.nextNeverStarts = true
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.clock.now() > 10.4)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func zeroStartingVolume() async {
    let rig = Rig()
    rig.music.vol = 0
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 1)
    #expect(rig.music.vol == 0)
}

@Test func runningHandlerFiresTrueThenFalse() async {
    let rig = Rig()
    let seen = Box<[Bool]>([])
    await rig.engine.setRunningHandler { seen.value.append($0) }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(seen.value == [true, false])
}

@Test func variationProducesDifferentRecipes() async {
    let rig = Rig(seed: 7)
    await rig.engine.djSkip(settings: TransitionSettings())
    let first = await rig.engine.lastRecipe
    rig.clock.advance(60)
    await rig.engine.djSkip(settings: TransitionSettings())
    let second = await rig.engine.lastRecipe
    #expect(first != nil && second != nil)
    #expect(first?.focus != second?.focus)
    #expect(first?.fadeTarget != second?.fadeTarget)
}
