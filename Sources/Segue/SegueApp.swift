import Foundation
import SegueCore

@main
struct SegueMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            return
        }
        print("Segue")
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
    }
}
