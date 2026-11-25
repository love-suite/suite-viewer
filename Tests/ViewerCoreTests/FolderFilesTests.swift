import SuiteCore
import Foundation
import Testing
@testable import ViewerCore
import SuiteFilesCore

@Suite struct FolderFilesTests {
    /// A scratch folder of the test's own, and a private defaults domain for its view options.
    private func withFolder(_ body: (URL, FolderViewStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "FolderFilesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(folder, FolderViewStore(defaults: defaults))
    }

    @Test func followsTheFoldersSortAndLeavesHiddenFilesOut() throws {
        try withFolder { folder, store in
            for (name, size) in [("b.jpg", 3), ("a10.png", 1), ("a2.png", 2), (".hidden.jpg", 9)] {
                try Data(count: size).write(to: folder.appendingPathComponent(name))
            }
            #expect(FolderFiles.sorted(folder, store: store).map(\.name) == ["a2.png", "a10.png", "b.jpg"])
            var options = FolderViewOptions()
            options.sortKey = .size
            options.ascending = false
            store.save(options, for: folder)
            #expect(FolderFiles.sorted(folder, store: store).map(\.name) == ["b.jpg", "a2.png", "a10.png"])
        }
    }

    @Test func aMissingFolderListsNothing() {
        #expect(FolderFiles.sorted(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}
