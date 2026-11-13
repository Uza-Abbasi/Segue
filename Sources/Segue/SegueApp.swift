import AppKit
import SegueCore
import SwiftUI

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
        SegueApp.main()
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
        let volume = music.volume() ?? 0
        print("volume: \(volume)")
        music.setVolume(volume - 10)
        Thread.sleep(forTimeInterval: 0.5)
        print("after lowering by 10: \(music.volume() ?? -1)")
        music.setVolume(volume)
        Thread.sleep(forTimeInterval: 0.2)
        print("after restoring: \(music.volume() ?? -1)")

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

struct SegueApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, settings: model.settings)
        } label: {
            // The symbol changes during a transition. A symbol effect here stops the item appearing at all.
            Image(systemName: model.isTransitioning ? "waveform.path" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var title = "Not playing"
    @Published var isPlaying = false
    @Published var isTransitioning = false
    @Published var hasAccessibility = AXEqualizerController.hasAccessibilityPermission
    @Published var canControlMusic = true
    @Published var shortcutError: String?
    @Published var recording: ShortcutRole?

    enum ShortcutRole { case skip, pause }

    let settings = SettingsStore()
    private let music = MusicAppController()
    private let equalizer = AXEqualizerController()
    private let engine: TransitionEngine
    private let hotkeys = HotkeyManager()
    private var timer: Timer?
    private var keyMonitor: Any?
    private var refreshing = false
    private var musicWasReachable = false

    init() {
        engine = TransitionEngine(music: music, eq: equalizer,
                                  store: SnapshotStore(directory: SnapshotStore.defaultDirectory),
                                  clock: SystemClock())
        let engine = engine, music = music
        Task {
            await engine.setRunningHandler { [weak self] running in
                Task { @MainActor in self?.isTransitioning = running }
            }
            await engine.recoverIfNeeded()
        }
        // Ask for permission to control Music up front, off the main thread because the prompt blocks.
        Task { [weak self] in
            _ = await Task.detached { music.automationStatus(prompt: true) }.value
            self?.refresh()
        }
        registerHotkeys()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelRecording() }
        }
    }

    func djSkip() {
        let s = settings.transition
        Task { await engine.djSkip(settings: s) }
    }

    func togglePause() {
        let s = settings.transition
        Task { await engine.togglePause(settings: s) }
    }

    func grantAccessibility() {
        AXEqualizerController.requestAccessibilityPermission()
    }

    /// Reads Music's state on a background thread, so a slow Music can't freeze the panel or the shortcuts.
    private func refresh() {
        hasAccessibility = AXEqualizerController.hasAccessibilityPermission
        guard !refreshing else { return }
        refreshing = true
        let music = music, engine = engine, wasReachable = musicWasReachable
        Task { [weak self] in
            let read = await Task.detached { () -> (OSStatus?, Bool, PlayerState, (name: String, artist: String)?) in
                let status = music.automationStatus(prompt: false)
                // No events until macOS has said yes: one sent earlier would raise the consent prompt.
                guard status == noErr else { return (status, music.isRunning, .stopped, nil) }
                // Music has just become reachable: put back anything an unfinished transition left.
                if !wasReachable { await engine.recoverIfNeeded() }
                return (status, true, music.playerState(), music.trackTitle())
            }.value
            guard let self else { return }
            let (status, running, state, track) = read
            self.refreshing = false
            self.musicWasReachable = status == noErr
            self.canControlMusic = status != OSStatus(errAEEventNotPermitted)
            self.isPlaying = state == .playing
            if let track {
                self.title = track.artist.isEmpty ? track.name : "\(track.name) — \(track.artist)"
            } else {
                self.title = running ? "Not playing" : "Music isn't open"
            }
        }
    }

    // MARK: - Shortcuts

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        let skipOK = hotkeys.register(settings.skipShortcut, id: 1) { [weak self] in self?.djSkip() }
        let pauseOK = hotkeys.register(settings.pauseShortcut, id: 2) { [weak self] in self?.togglePause() }
        shortcutError = skipOK && pauseOK ? nil : "A shortcut is in use by another app. Pick a different one."
    }

    /// Captures the next key press that includes ⌃, ⌥ or ⌘ as the new shortcut. Esc cancels.
    func record(_ role: ShortcutRole) {
        stopRecording()
        recording = role
        hotkeys.unregisterAll()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
                self.registerHotkeys()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else { return nil }
            self.assign(shortcut, to: role)
            return nil
        }
    }

    private func assign(_ shortcut: Shortcut, to role: ShortcutRole) {
        stopRecording()
        let old = (settings.skipShortcut, settings.pauseShortcut)
        let other = role == .skip ? settings.pauseShortcut : settings.skipShortcut
        guard shortcut.keyCode != other.keyCode || shortcut.modifiers != other.modifiers else {
            registerHotkeys()
            shortcutError = "\(shortcut.display) is already the other shortcut. The shortcut was not changed."
            return
        }
        if role == .skip { settings.skipShortcut = shortcut } else { settings.pauseShortcut = shortcut }
        registerHotkeys()
        if shortcutError != nil {
            // Refused: go back to the shortcuts that worked.
            (settings.skipShortcut, settings.pauseShortcut) = old
            registerHotkeys()
            shortcutError = "\(shortcut.display) is unavailable. The shortcut was not changed."
        }
    }

    /// Ends a recording that was never finished, so the shortcuts work again.
    func cancelRecording() {
        guard recording != nil else { return }
        stopRecording()
        registerHotkeys()
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
    }
}
