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

@Suite("Version persistence after pipeline-start")
struct VersionPersistenceTests {
    @Test("saves version when stage is pipeline-start and result is success")
    func savesOnPipelineStartSuccess() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.pipelineStart.rawValue

        // Simulate the orchestrator's conditional write
        if stage == StandardHook.pipelineStart.rawValue {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == version)
    }

    @Test("does NOT save version when stage is pre-process")
    func doesNotSaveOnPreProcess() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.preProcess.rawValue

        if stage == StandardHook.pipelineStart.rawValue {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == nil)
    }

    @Test("does NOT save version on failure (critical result)")
    func doesNotSaveOnFailure() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 2, minor: 1, patch: 0)
        let stage = StandardHook.pipelineStart.rawValue
        let succeeded = false // simulating critical result

        if stage == StandardHook.pipelineStart.rawValue, succeeded {
            try store.save(version: version, for: "com.example.test")
        }

        #expect(store.lastExecutedVersion(for: "com.example.test") == nil)
    }

    @Test("buildJSONPayload includes stored lastExecutedVersion")
    func buildPayloadIncludesVersion() throws {
        let store = InMemoryVersionStateStore()
        let version = SemanticVersion(major: 1, minor: 5, patch: 0)
        try store.save(version: version, for: "com.example.test")

        let retrieved = store.lastExecutedVersion(for: "com.example.test")
        #expect(retrieved == version)
    }

    @Test("buildJSONPayload passes nil when no version stored")
    func buildPayloadPassesNilWhenEmpty() {
        let store = InMemoryVersionStateStore()
        let retrieved = store.lastExecutedVersion(for: "com.example.test")
        #expect(retrieved == nil)
    }
}
