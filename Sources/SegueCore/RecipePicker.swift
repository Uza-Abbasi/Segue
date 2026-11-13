/// Picks a transition recipe for each skip so that consecutive skips sound different.
public struct RecipePicker: Sendable {
    public static let fadeTargets: [Double] = [0, 0.25, 0.45, 0.6]
    public static let lengthLimits = 1.0...12.0

    public private(set) var last: Recipe?

    public init() {}

    public mutating func next(settings: TransitionSettings, eqAvailable: Bool,
                              using rng: inout some RandomNumberGenerator) -> Recipe {
        let a = Self.clamp(settings.minLength), b = Self.clamp(settings.maxLength)
        let range = min(a, b)...max(a, b)
        let useEQ = eqAvailable && settings.eqEffects

        let recipe: Recipe
        if settings.variation {
            let focuses = useEQ ? EQFocus.allCases.filter { $0 != last?.focus } : [.none]
            let targets = Self.fadeTargets.filter { $0 != last?.fadeTarget }
            recipe = Recipe(
                length: Double.random(in: range, using: &rng),
                fadeTarget: targets.randomElement(using: &rng)!,
                shape: FadeShape.allCases.randomElement(using: &rng)!,
                focus: focuses.randomElement(using: &rng)!,
                depth: Int.random(in: -1200 ... -600, using: &rng))
        } else {
            recipe = Recipe(length: (range.lowerBound + range.upperBound) / 2, fadeTarget: 0,
                            shape: .steady, focus: useEQ ? .lows : .none, depth: -1200)
        }
        last = recipe
        return recipe
    }

    private static func clamp(_ seconds: Double) -> Double {
        min(max(seconds, lengthLimits.lowerBound), lengthLimits.upperBound)
    }
}
