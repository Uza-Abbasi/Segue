import Testing
@testable import SegueCore

@Test(arguments: FadeShape.allCases) func levelEndpoints(shape: FadeShape) {
    #expect(FadeCurve.level(shape, progress: 0) == 1)
    #expect(FadeCurve.level(shape, progress: 1) == 0)
    #expect(FadeCurve.level(shape, progress: 1.7) == 0)
}

@Test(arguments: FadeShape.allCases) func levelNeverRises(shape: FadeShape) {
    let xs = stride(from: 0.0, through: 1.0, by: 0.01).map { FadeCurve.level(shape, progress: $0) }
    #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 >= $1 })
}

@Test func shapesDifferAtMidpoint() {
    #expect(FadeCurve.level(.earlyDrop, progress: 0.5) < FadeCurve.level(.steady, progress: 0.5))
    #expect(FadeCurve.level(.steady, progress: 0.5) < FadeCurve.level(.lateDrop, progress: 0.5))
}

@Test func volumeStopsAtFadeTarget() {
    let r = Recipe(length: 4, fadeTarget: 0.25, shape: .steady, focus: .none, depth: -1200)
    #expect(FadeCurve.volume(start: 80, recipe: r, progress: 0) == 80)
    #expect(FadeCurve.volume(start: 80, recipe: r, progress: 1) == 20)
    #expect(FadeCurve.volume(start: 0, recipe: r, progress: 0.5) == 0)
}

@Test func lowsCutMovesLowBandsOnly() {
    let r = Recipe(length: 4, fadeTarget: 0, shape: .steady, focus: .lows, depth: -1200)
    let orig = [Int](repeating: 100, count: 10)
    let end = FadeCurve.bands(original: orig, recipe: r, progress: 1)
    #expect(end == [0: -1200, 1: -1200, 2: -1200, 3: -1200, 4: -600])
    #expect(FadeCurve.bands(original: orig, recipe: r, progress: 0) == [0: 100, 1: 100, 2: 100, 3: 100, 4: 100])
}

@Test func focusWeights() {
    #expect(EQFocus.none.bandWeights.isEmpty)
    #expect(EQFocus.mids.bandWeights == [3: 0.5, 4: 1, 5: 1, 6: 1, 7: 0.5])
    #expect(EQFocus.highs.bandWeights == [6: 0.5, 7: 1, 8: 1, 9: 1])
    #expect(EQFocus.lowsAndHighs.bandWeights == [0: 1, 1: 1, 2: 1, 3: 1, 4: 0.5, 6: 0.5, 7: 1, 8: 1, 9: 1])
}
