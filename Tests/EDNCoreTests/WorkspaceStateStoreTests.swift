import Foundation
import Testing
@testable import EDNCore

@Suite("Workspace state store")
struct WorkspaceStateStoreTests {
    @Test("Each update reloads and preserves prior process changes")
    func updatesStartFromLatestDiskState() throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let first = WorkspaceStateStore(url: fixture.stateURL)
        let second = WorkspaceStateStore(url: fixture.stateURL)

        try first.update { state in
            state.setFrame(Frame(x: 1, y: 2, w: 3, h: 4), workspace: "one", key: "app.one")
        }
        try second.update { state in
            state.setFrame(Frame(x: 5, y: 6, w: 7, h: 8), workspace: "two", key: "app.two")
        }

        let state = try first.read()
        #expect(state.frame(workspace: "one", key: "app.one") == Frame(x: 1, y: 2, w: 3, h: 4))
        #expect(state.frame(workspace: "two", key: "app.two") == Frame(x: 5, y: 6, w: 7, h: 8))
    }

    @Test("Legacy single frames upgrade transparently to app window sets")
    func legacyFrameBecomesWindowSet() throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let store = WorkspaceStateStore(url: fixture.stateURL)
        let frame = Frame(x: 1, y: 2, w: 800, h: 600)
        try WorkspaceState(frames: ["work": ["app.browser": frame]])
            .save(to: fixture.stateURL)

        var state = try store.read()
        #expect(state.windowFrames(workspace: "work", key: "app.browser") == [frame])

        let second = Frame(x: 801, y: 2, w: 800, h: 600)
        state.setWindowFrames([frame, second], workspace: "work", key: "app.browser")
        try state.save(to: fixture.stateURL)
        #expect(try store.read().windowFrames(workspace: "work", key: "app.browser") == [frame, second])
    }

    @Test("A failed transaction does not write partial state")
    func failedUpdateDoesNotPersist() throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let store = WorkspaceStateStore(url: fixture.stateURL)
        try WorkspaceState(activeWorkspace: "original").save(to: fixture.stateURL)

        do {
            try store.update { state in
                state.activeWorkspace = "partial"
                throw TestFailure.expected
            }
            Issue.record("Expected transaction to throw")
        } catch TestFailure.expected {}

        #expect(try store.read().activeWorkspace == "original")
    }

    @Test("Corrupt state is preserved before an empty recovery state is returned")
    func corruptStateIsBackedUp() throws {
        let fixture = try StateFixture()
        defer { fixture.remove() }
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fixture.stateURL)

        let recovered = try WorkspaceStateStore(url: fixture.stateURL).read()

        #expect(recovered == WorkspaceState())
        #expect(try Data(contentsOf: fixture.stateURL.appendingPathExtension("corrupt")) == corrupt)
    }
}

private enum TestFailure: Error {
    case expected
}

private struct StateFixture {
    let root: URL
    let stateURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-state-\(UUID().uuidString)")
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
