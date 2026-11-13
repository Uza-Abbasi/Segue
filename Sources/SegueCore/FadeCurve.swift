import Foundation

public enum FadeCurve {
    /// 1 at the start of a fade, 0 at the end.
    public static func level(_ shape: FadeShape, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch shape {
        case .steady: return 1 - p
        case .earlyDrop: return (1 - p) * (1 - p)
        case .lateDrop: return 1 - p * p
        }
    }

    public static func volume(start: Int, recipe: Recipe, progress: Double) -> Int {
        let share = recipe.fadeTarget + (1 - recipe.fadeTarget) * level(recipe.shape, progress: progress)
        return Int((Double(start) * share).rounded())
    }

    /// Values for the bands the recipe's focus touches; other bands are left out.
    public static func bands(original: [Int], recipe: Recipe, progress: Double) -> [Int: Int] {
        // The filter moves ahead of the volume so it is heard before the fade takes over.
        let p = pow(min(max(progress, 0), 1), 0.6)
        var out: [Int: Int] = [:]
        for (band, weight) in recipe.focus.bandWeights where original.indices.contains(band) {
            let from = Double(original[band])
            let to = Double(recipe.depth) * weight
            out[band] = Int((from + (to - from) * p).rounded())
        }
        return out
    }
}
