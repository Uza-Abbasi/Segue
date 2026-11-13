import Testing
@testable import SegueCore

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func picks(_ n: Int, settings: TransitionSettings = .init(), eqAvailable: Bool = true) -> [Recipe] {
    var picker = RecipePicker()
    var rng = SplitMix64(seed: 42)
    return (0..<n).map { _ in picker.next(settings: settings, eqAvailable: eqAvailable, using: &rng) }
}

@Test func valuesStayInRange() {
    for r in picks(500) {
        #expect((3.0...8.0).contains(r.length))
        #expect(RecipePicker.fadeTargets.contains(r.fadeTarget))
        #expect((-1200 ... -600).contains(r.depth))
    }
}

@Test func neverRepeatsFocusOrTarget() {
    let rs = picks(500)
    for (a, b) in zip(rs, rs.dropFirst()) {
        #expect(a.focus != b.focus)
        #expect(a.fadeTarget != b.fadeTarget)
    }
    #expect(Set(rs.map(\.focus)).count == EQFocus.allCases.count)
    #expect(Set(rs.map(\.shape)).count == FadeShape.allCases.count)
}

@Test func eqUnavailableGivesNoFocusButStillVariesTarget() {
    let rs = picks(200, eqAvailable: false)
    #expect(rs.allSatisfy { $0.focus == .none })
    for (a, b) in zip(rs, rs.dropFirst()) { #expect(a.fadeTarget != b.fadeTarget) }
}

@Test func eqEffectsOffGivesNoFocus() {
    var s = TransitionSettings()
    s.eqEffects = false
    #expect(picks(100, settings: s).allSatisfy { $0.focus == .none })
}

@Test func variationOffIsFixed() {
    var s = TransitionSettings()
    s.variation = false
    let fixed = Recipe(length: 5.5, fadeTarget: 0, shape: .steady, focus: .lows, depth: -1200)
    #expect(picks(5, settings: s).allSatisfy { $0 == fixed })
    var noEQ = fixed
    noEQ.focus = .none
    #expect(picks(5, settings: s, eqAvailable: false).allSatisfy { $0 == noEQ })
}

@Test func badRangeIsClampedAndSwapped() {
    var s = TransitionSettings()
    s.minLength = 20
    s.maxLength = 0.2
    #expect(picks(100, settings: s).allSatisfy { (1.0...12.0).contains($0.length) })
    s.minLength = 4
    s.maxLength = 4
    #expect(picks(20, settings: s).allSatisfy { $0.length == 4 })
}
