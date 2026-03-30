import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("VersionStateStore")
struct VersionStateStoreTests {
    @Test("returns nil for unknown plugin")
    func returnsNilForUnknownPlugin() {
        let store = InMemoryVersionStateStore()
        #expect(store.lastExecutedVersion(for: "com.example.unknown") == nil)
    }

    @Test("round-trips a saved version")
    func roundTrips() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 1, minor: 2, patch: 0)
        try store.save(version: version, for: "com.example.foo")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == version)
    }

    @Test("overwrite replaces previous version")
    func overwriteReplaces() throws {
        let store = InMemoryVersionStateStore()
        try store.save(version: SemanticVersion(major: 1, minor: 0, patch: 0), for: "com.example.foo")
        try store.save(version: SemanticVersion(major: 2, minor: 0, patch: 0), for: "com.example.foo")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == SemanticVersion(major: 2, minor: 0, patch: 0))
    }

    @Test("stores versions independently per plugin")
    func independentPerPlugin() throws {
        let store = InMemoryVersionStateStore()
        try store.save(version: SemanticVersion(major: 1, minor: 0, patch: 0), for: "com.example.foo")
        try store.save(version: SemanticVersion(major: 3, minor: 0, patch: 0), for: "com.example.bar")
        #expect(store.lastExecutedVersion(for: "com.example.foo") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(store.lastExecutedVersion(for: "com.example.bar") == SemanticVersion(major: 3, minor: 0, patch: 0))
    }
}
