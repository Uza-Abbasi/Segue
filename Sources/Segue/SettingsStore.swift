import Foundation
import SegueCore
import ServiceManagement

/// User settings, saved to UserDefaults as they change.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var transition: TransitionSettings { didSet { save(transition, "segue.transition") } }
    @Published var skipShortcut: Shortcut { didSet { save(skipShortcut, "segue.skipShortcut") } }
    @Published var pauseShortcut: Shortcut { didSet { save(pauseShortcut, "segue.pauseShortcut") } }
    @Published var startAtLogin: Bool {
        didSet {
            guard startAtLogin != oldValue, startAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if startAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                // Only works from the packaged app; put the switch back if macOS refuses.
                startAtLogin = oldValue
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transition = Self.load("segue.transition", from: defaults) ?? TransitionSettings()
        skipShortcut = Self.load("segue.skipShortcut", from: defaults) ?? .djSkip
        pauseShortcut = Self.load("segue.pauseShortcut", from: defaults) ?? .pause
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
