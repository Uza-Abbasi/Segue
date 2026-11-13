import Foundation
import Testing
@testable import SegueCore

@Test func secondPressDuringFadeOutSkipsInstantly() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(2.0) { await rig.engine.djSkip(settings: fixedSettings) }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 1)
    #expect(rig.clock.now() < 2.2)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
    #expect(await rig.engine.isRunning == false)
}

@Test func pressDuringFadeInFinishesAtFullVolume() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(6.0) { await rig.engine.djSkip(settings: fixedSettings) }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 2)
    #expect(rig.clock.now() < 6.2)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func skipWithinThreeSecondsOfATransitionIsInstant() async {
    let rig = Rig()
    await rig.engine.djSkip(settings: fixedSettings)
    let logBefore = rig.music.log
    rig.clock.advance(2)
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.log == logBefore + ["next"])
}

@Test func searchModeLastsUntilTenSecondsWithoutASkip() async {
    let rig = Rig()
    await rig.engine.djSkip(settings: fixedSettings)
    rig.clock.advance(2)
    await rig.engine.djSkip(settings: fixedSettings)      // enters search mode
    for _ in 0..<3 {
        rig.clock.advance(4)
        let logBefore = rig.music.log
        await rig.engine.djSkip(settings: fixedSettings)
        #expect(rig.music.log == logBefore + ["next"])
    }
    rig.clock.advance(10.1)
    let sweepsBefore = rig.eq.setBandsCalls
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.setBandsCalls > sweepsBefore + 100)
}

@Test func skipAfterThreeSecondsIsNormal() async {
    let rig = Rig()
    await rig.engine.djSkip(settings: fixedSettings)
    rig.clock.advance(3.1)
    let sweepsBefore = rig.eq.setBandsCalls
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.setBandsCalls > sweepsBefore + 100)
}

@Test func trackChangeMidTransitionAbortsWithoutSkip() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(2.0) { rig.music.key = "other" }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 0)
    #expect(rig.clock.now() < 2.2)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func userVolumeChangeIsRespected() async {
    let rig = Rig()
    rig.eq.current = rock
    let logCount = Box(0), sweeps = Box(0)
    rig.clock.at(2.0) {
        rig.music.vol = 55
        logCount.value = rig.music.log.count
        sweeps.value = rig.eq.setBandsCalls
    }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.vol == 55)
    #expect(rig.music.log.dropFirst(logCount.value).allSatisfy { !$0.hasPrefix("vol:") })
    #expect(rig.music.nextCount == 1)
    #expect(rig.eq.setBandsCalls > sweeps.value + 50)
    #expect(rig.eq.current == rock)
}

@Test func eqFailureMidSweepFallsBackToFade() async {
    let rig = Rig()
    rig.eq.failAfterSetBandsCalls = 10
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 1)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.setBandsCalls == 10)
}

@Test func eqIsRestoredAfterAFailureOnceItsControlsAreFoundAgain() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.eq.failAfterSetBandsCalls = 10
    rig.clock.at(1.0) { rig.eq.failAfterSetBandsCalls = nil }   // window comes back
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func eqThatCannotBeRestoredStaysOnDiskUntilItCan() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.eq.failAfterSetBandsCalls = 10
    rig.clock.at(1.0) { rig.eq.available = false }              // window gone for good
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.vol == 80)
    #expect(rig.store.load() == StateSnapshot(volume: nil, eq: rock))

    rig.eq.available = true
    rig.eq.failAfterSetBandsCalls = nil
    rig.music.vol = 30                                          // the user's own later change
    await rig.engine.recoverIfNeeded()
    #expect(rig.eq.current == rock)
    #expect(rig.music.vol == 30)
    #expect(rig.store.load() == nil)
}

@Test func nextSkipAfterMusicComesBackRestoresFirst() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(2.0) { rig.music.running = false }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.vol < 80)

    rig.music.running = true
    rig.music.state = .paused
    await rig.engine.djSkip(settings: fixedSettings)            // plain skip while paused
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func recoverKeepsTheEQWhenItIsNotReachableYet() async {
    let rig = Rig()
    rig.eq.available = false
    rig.store.save(StateSnapshot(volume: 70, eq: rock))
    await rig.engine.recoverIfNeeded()
    #expect(rig.music.vol == 70)
    #expect(rig.store.load() == StateSnapshot(volume: nil, eq: rock))
}

@Test func oneFailedVolumeReadDoesNotStrandTheVolume() async {
    let rig = Rig()
    rig.clock.at(2.0) { rig.music.failVolumeReads = 1 }
    rig.clock.at(6.0) { rig.music.failVolumeReads = 1 }         // and once during the fade-in
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 1)
    #expect(rig.music.vol == 80)
}

@Test func unreadableVolumeAtTheStartIsAPlainSkip() async {
    let rig = Rig()
    rig.music.failVolumeReads = 1
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.log == ["next"])
    #expect(rig.store.load() == nil)
}

@Test func skipAfterAnAbortedTransitionIsNotSearchMode() async {
    let rig = Rig()
    rig.clock.at(2.0) { rig.music.key = "other" }
    await rig.engine.djSkip(settings: fixedSettings)            // aborted: the song changed
    rig.clock.advance(1)
    let sweepsBefore = rig.eq.setBandsCalls
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.setBandsCalls > sweepsBefore + 100)
}

@Test func musicQuitsMidTransition() async {
    let rig = Rig()
    rig.clock.at(2.0) { rig.music.running = false }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.clock.now() < 2.2)
    #expect(await rig.engine.isRunning == false)
    #expect(rig.store.load() != nil)
    #expect(rig.music.nextCount == 0)
}

@Test func recoverRestoresAndClears() async {
    let rig = Rig()
    rig.store.save(StateSnapshot(volume: 70, eq: rock))
    await rig.engine.recoverIfNeeded()
    #expect(rig.music.vol == 70)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
}

@Test func recoverWaitsForMusic() async {
    let rig = Rig()
    rig.music.running = false
    rig.store.save(StateSnapshot(volume: 70, eq: rock))
    await rig.engine.recoverIfNeeded()
    #expect(rig.music.log.isEmpty)
    #expect(rig.store.load() != nil)
}

@Test func recoverWithNothingOnDiskDoesNothing() async {
    let rig = Rig()
    await rig.engine.recoverIfNeeded()
    #expect(rig.music.log.isEmpty)
    #expect(rig.eq.restoreCalls == 0)
}

// Music animates a preset back for about half a second, and its window reads stale meanwhile.
@Test func skipRightAfterARestoreDoesNotSaveTheSweptEQ() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.eq.readsLagRestore = true
    rig.clock.at(2.0) { rig.music.key = "other" }
    await rig.engine.djSkip(settings: fixedSettings)      // aborted: EQ restored at about 2 s
    await rig.engine.djSkip(settings: fixedSettings)      // pressed again straight away
    #expect(rig.music.nextCount == 1)
    #expect(rig.eq.current == rock)
}

@Test func skipRightAfterRecoveryDoesNotSaveTheSweptEQ() async {
    let rig = Rig()
    var swept = rock
    swept.preset = "Manual"
    swept.bands[0] = -1184
    rig.eq.current = swept
    rig.eq.readsLagRestore = true
    rig.store.save(StateSnapshot(volume: nil, eq: rock))
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.current == rock)
}

@Test func eqIsReadAfreshOnceARestoreHasSettled() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(2.0) { rig.music.key = "other" }
    await rig.engine.djSkip(settings: fixedSettings)
    rig.clock.advance(TransitionEngine.eqSettleTime + 0.1)
    var mine = rock
    mine.preset = "Jazz"
    rig.eq.current = mine                                 // the user picked another preset
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.current == mine)
}
