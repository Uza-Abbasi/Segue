import Foundation
import Testing
@testable import SegueCore

@Test func pauseFadesThenPausesThenRestoresVolume() async {
    let rig = Rig()
    await rig.engine.togglePause(settings: fixedSettings)
    let i = rig.music.log.firstIndex(of: "pause")!
    let before = rig.music.log[..<i].compactMap { Int($0.dropFirst(4)) }
    #expect(before.count > 10)
    #expect(isNonIncreasing(before))
    #expect(before.last! <= 10)
    #expect(Array(rig.music.log[(i + 1)...]) == ["vol:80"])
    #expect(rig.music.state == .paused)
    #expect(abs(rig.clock.now() - 0.6) < 0.1)
    #expect(await rig.engine.isRunning == false)
}

@Test func resumeStartsSilentAndFadesUp() async {
    let rig = Rig()
    rig.music.state = .paused
    await rig.engine.togglePause(settings: fixedSettings)
    #expect(Array(rig.music.log.prefix(2)) == ["vol:0", "play"])
    let after = rig.music.log.dropFirst(2).compactMap { Int($0.dropFirst(4)) }
    #expect(after.count > 10)
    #expect(isNonDecreasing(after))
    #expect(rig.music.vol == 80)
    #expect(abs(rig.clock.now() - 0.6) < 0.1)
}

@Test func settingOffIsPlainToggle() async {
    var s = fixedSettings
    s.fadeOnPause = false
    let playing = Rig()
    await playing.engine.togglePause(settings: s)
    #expect(playing.music.log == ["pause"])
    let paused = Rig()
    paused.music.state = .paused
    await paused.engine.togglePause(settings: s)
    #expect(paused.music.log == ["play"])
    #expect(paused.clock.now() == 0)
}

@Test func stoppedStateJustPlays() async {
    let rig = Rig()
    rig.music.state = .stopped
    await rig.engine.togglePause(settings: fixedSettings)
    #expect(rig.music.log == ["play"])
}

@Test func pauseDuringDJSkipCancelsAndPauses() async {
    let rig = Rig()
    rig.eq.current = rock
    rig.clock.at(2.0) { await rig.engine.togglePause(settings: fixedSettings) }
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.music.nextCount == 0)
    #expect(rig.music.state == .paused)
    #expect(rig.music.vol == 80)
    #expect(rig.eq.current == rock)
    #expect(rig.store.load() == nil)
    #expect(rig.clock.now() < 2.2)
}

@Test func userVolumeChangeDuringPauseFadeIsKept() async {
    let rig = Rig()
    rig.clock.at(0.3) { rig.music.vol = 60 }
    await rig.engine.togglePause(settings: fixedSettings)
    #expect(rig.music.log.contains("pause"))
    #expect(rig.music.vol == 60)
}

@Test func pauseWhenMusicNotRunningDoesNothing() async {
    let rig = Rig()
    rig.music.running = false
    await rig.engine.togglePause(settings: fixedSettings)
    #expect(rig.music.log.isEmpty)
}

@Test func skipRightAfterResumeIsAFullTransition() async {
    let rig = Rig()
    rig.music.state = .paused
    await rig.engine.togglePause(settings: fixedSettings)
    rig.clock.advance(1)
    await rig.engine.djSkip(settings: fixedSettings)
    #expect(rig.eq.setBandsCalls > 100)
}
