import Foundation
import Testing
@testable import SegueCore

func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("segue-tests-\(UUID().uuidString)")
}

private let eq = EQSnapshot(enabled: true, preset: "Rock", bands: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

@Test func roundTrip() {
    let store = SnapshotStore(directory: tempDirectory())
    let withEQ = StateSnapshot(volume: 80, eq: eq)
    store.save(withEQ)
    #expect(store.load() == withEQ)
    let withoutEQ = StateSnapshot(volume: 12, eq: nil)
    store.save(withoutEQ)
    #expect(store.load() == withoutEQ)
}

@Test func loadMissingIsNil() {
    #expect(SnapshotStore(directory: tempDirectory()).load() == nil)
}

@Test func clearRemoves() {
    let store = SnapshotStore(directory: tempDirectory())
    store.save(StateSnapshot(volume: 80, eq: eq))
    store.clear()
    #expect(store.load() == nil)
}

@Test func corruptFileIsNil() throws {
    let dir = tempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("snapshot.json"))
    #expect(SnapshotStore(directory: dir).load() == nil)
}

@Test func saveCreatesDirectory() {
    let dir = tempDirectory().appendingPathComponent("nested")
    let store = SnapshotStore(directory: dir)
    store.save(StateSnapshot(volume: 5, eq: nil))
    #expect(store.load()?.volume == 5)
}
