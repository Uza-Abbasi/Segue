import Foundation
import SegueCore

@main
struct SegueMain {
    static func main() {
        if CommandLine.arguments.contains("--probe-preset") {
            Probe.preset()
            return
        }
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            return
        }
        print("Segue")
    }
}

extension Probe {
    /// `Segue --probe-preset`: a named preset with the EQ off must survive a sweep.
    static func preset() {
        let eq = AXEqualizerController()
        guard eq.prepare(), let original = try? eq.snapshot() else { return print("prepare failed") }
        do {
            try eq.restore(EQSnapshot(enabled: false, preset: "Rock", bands: original.bands))
            Thread.sleep(forTimeInterval: 1.5)
            let rock = try eq.snapshot()
            print("set up: \(rock)")
            try eq.setEnabled(true)
            try eq.setBands([0: -1200, 1: -1200, 2: -1200, 3: -1200, 4: -600])
            Thread.sleep(forTimeInterval: 0.5)
            print("during: \(try eq.snapshot())")
            let t0 = Date()
            try eq.restore(rock)
            print(String(format: "restore call took %.0f ms", Date().timeIntervalSince(t0) * 1000))
            for wait in [0.1, 0.3, 0.6, 1.0] {
                Thread.sleep(forTimeInterval: wait)
                let now = try eq.snapshot()
                print("after +\(wait)s: \(now == rock ? "restored" : "\(now)")")
            }
            try eq.restore(original)
            Thread.sleep(forTimeInterval: 1.5)
            print("original back: \(try eq.snapshot() == original)")
        } catch {
            print("error: \(error)")
        }
    }
}

/// `Segue --probe`: checks the live connection to Music without starting the app.
enum Probe {
    static func run() {
        let music = MusicAppController()
        print("running: \(music.isRunning)")
        guard music.isRunning else { return }
        print("state: \(music.playerState())")
        print("trackKey: \(music.trackKey() ?? "nil")")
        let volume = music.volume()
        print("volume: \(volume)")
        music.setVolume(volume - 10)
        Thread.sleep(forTimeInterval: 0.5)
        print("after lowering by 10: \(music.volume())")
        music.setVolume(volume)
        Thread.sleep(forTimeInterval: 0.2)
        print("after restoring: \(music.volume())")

        // How quickly a write shows up in a read, which the engine's user-volume check depends on.
        var stale = 0
        let start = Date()
        for i in 0..<30 {
            let v = volume - (i % 2 == 0 ? 3 : 0)
            music.setVolume(v)
            if music.volume() != v { stale += 1 }
        }
        music.setVolume(volume)
        print(String(format: "30 write+read pairs: %.1f ms each, %d stale reads", Date().timeIntervalSince(start) / 30 * 1000, stale))

        let eq = AXEqualizerController()
        print("accessibility permission: \(AXEqualizerController.hasAccessibilityPermission)")
        let prepared = eq.prepare()
        print("prepare: \(prepared)")
        guard prepared, let before = try? eq.snapshot() else { return }
        print("snapshot: \(before)")
        do {
            if !before.enabled { try eq.setEnabled(true) }
            let t0 = Date()
            for i in 0..<60 { try eq.setBands([0: -20 * i, 1: -20 * i, 2: -20 * i, 3: -20 * i, 4: -20 * i]) }
            print(String(format: "60 five-band updates: %.1f ms each", Date().timeIntervalSince(t0) / 60 * 1000))
            try eq.setBands([0: -1200, 1: -1200, 2: -1200, 3: -1200, 4: -1200])
            Thread.sleep(forTimeInterval: 3)
            try eq.restore(before)
            Thread.sleep(forTimeInterval: 0.3)
            let after = try eq.snapshot()
            print("restored: \(after)")
            print("matches original: \(after == before)")
        } catch {
            print("error: \(error)")
        }
    }
}
