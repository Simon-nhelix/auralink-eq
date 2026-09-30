import XCTest
@testable import AuralinkCore

final class DirectoryWatcherTests: XCTestCase {
    private var root: URL!
    private var watcher: DirectoryWatcher?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralinkWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        watcher?.cancel()
        watcher = nil
        try FileManager.default.removeItem(at: root)
    }

    /// Wait for observable contents rather than counting coalesced vnode events.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var predicate: (@Sendable () -> Bool)?
        private var expectation: XCTestExpectation?

        func expect(_ expectation: XCTestExpectation, when predicate: @escaping @Sendable () -> Bool) {
            lock.lock()
            self.expectation = expectation
            self.predicate = predicate
            lock.unlock()
        }

        func changed() {
            lock.lock()
            if let predicate, predicate() {
                let matched = expectation
                expectation = nil
                self.predicate = nil
                lock.unlock()
                matched?.fulfill()
            } else {
                lock.unlock()
            }
        }
    }

    private func start(_ target: URL) -> Observation {
        let observation = Observation()
        watcher = DirectoryWatcher(url: target) { observation.changed() }
        return observation
    }

    private func assertObservedWrite(_ target: URL, observation: Observation, name: String) throws {
        let file = target.appendingPathComponent(name)
        let changed = expectation(description: "Observed \(name)")
        observation.expect(changed) { FileManager.default.fileExists(atPath: file.path) }
        try Data(name.utf8).write(to: file, options: .atomic)
        wait(for: [changed], timeout: 5)
    }

    func testExistingDirectoryObservesAtomicWrites() throws {
        let target = root.appendingPathComponent("presets", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let observation = start(target)
        try assertObservedWrite(target, observation: observation, name: "first.json")
        try assertObservedWrite(target, observation: observation, name: "second.json")
    }

    func testMissingCollectionAppearsWithoutAnExplicitReload() throws {
        let target = root.appendingPathComponent("collection/presets", isDirectory: true)
        let observation = start(target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let appeared = expectation(description: "Collection appeared")
        observation.expect(appeared) { FileManager.default.fileExists(atPath: target.path) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        wait(for: [appeared], timeout: 5)
        try assertObservedWrite(target, observation: observation, name: "cloned.json")
    }

    func testDeletedDirectoryReattachesAfterRecreation() throws {
        let target = root.appendingPathComponent("presets", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let observation = start(target)
        let removed = expectation(description: "Directory removed")
        observation.expect(removed) { !FileManager.default.fileExists(atPath: target.path) }
        try FileManager.default.removeItem(at: target)
        wait(for: [removed], timeout: 5)
        let appeared = expectation(description: "Directory recreated")
        observation.expect(appeared) { FileManager.default.fileExists(atPath: target.path) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        wait(for: [appeared], timeout: 5)
        try assertObservedWrite(target, observation: observation, name: "recreated.json")
    }

    func testReplacingCollectionRootReattachesToNewContents() throws {
        let collection = root.appendingPathComponent("collection", isDirectory: true)
        let target = collection.appendingPathComponent("presets", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let observation = start(target)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        let replacementPresets = replacement.appendingPathComponent("presets", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementPresets, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: replacementPresets.appendingPathComponent("new.json"))
        let replaced = expectation(description: "New collection observed")
        observation.expect(replaced) {
            FileManager.default.fileExists(atPath: target.appendingPathComponent("new.json").path)
        }
        try FileManager.default.moveItem(at: collection, to: root.appendingPathComponent("old"))
        try FileManager.default.moveItem(at: replacement, to: collection)
        wait(for: [replaced], timeout: 5)
        try assertObservedWrite(target, observation: observation, name: "after-replacement.json")
    }

    func testCancelStopsCallbacksAndReleaseDoesNotRetainWatcher() throws {
        let target = root.appendingPathComponent("presets", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let callback = expectation(description: "No callback after cancellation")
        callback.isInverted = true
        watcher = DirectoryWatcher(url: target) { callback.fulfill() }
        weak let released = watcher
        watcher?.cancel()
        watcher = nil
        XCTAssertNil(released)
        try Data("ignored".utf8).write(to: target.appendingPathComponent("ignored.json"))
        wait(for: [callback], timeout: 0.2)
    }
}
