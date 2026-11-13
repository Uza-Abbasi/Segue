import Foundation

/// Keeps the pre-transition state on disk so it can be restored if the app dies mid-transition.
public struct SnapshotStore: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent("snapshot.json")
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Segue")
    }

    public func save(_ s: StateSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Nil if there is no snapshot or it can't be read.
    public func load() -> StateSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(StateSnapshot.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
