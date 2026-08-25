import Foundation
import Testing
@testable import EDNCore

@Suite("Legacy storage migration")
struct StorageMigrationTests {
    @Test("Copies a legacy file while preserving the source")
    func migrationCopiesLegacyFileAndPreservesSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("legacy/config.json")
        let destination = root.appendingPathComponent("edn/config.json")
        let original = Data("legacy-layout".utf8)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: source)

        #expect(try StorageMigration.copyIfNeeded(from: source, to: destination))
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("Never overwrites an existing EDN file")
    func migrationNeverOverwritesExistingEDNFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("legacy/state.json")
        let destination = root.appendingPathComponent("edn/state.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: source)
        try Data("current-edn".utf8).write(to: destination)

        #expect(try !StorageMigration.copyIfNeeded(from: source, to: destination))
        #expect(try Data(contentsOf: destination) == Data("current-edn".utf8))
    }
}
