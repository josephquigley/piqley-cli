import Foundation
import Testing
@testable import piqley

@Suite("ForkManager")
struct ForkManagerTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-fork-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createTestImage(at url: URL, name: String) throws {
        let path = url.appendingPathComponent(name).path
        try TestFixtures.createTestJPEG(at: path, width: 100, height: 100)
    }

    @Test("getOrCreateFork copies files to fork directory")
    func testGetOrCreateFork() async throws {
        let baseDir = try makeTempDir()
        let sourceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        try createTestImage(at: sourceDir, name: "photo1.jpg")
        try createTestImage(at: sourceDir, name: "photo2.jpg")

        let manager = ForkManager(baseURL: baseDir)
        let forkURL = try await manager.getOrCreateFork(
            pluginId: "test-plugin",
            sourceURL: sourceDir
        )

        let contents = try FileManager.default.contentsOfDirectory(
            at: forkURL, includingPropertiesForKeys: nil
        )
        let names = Set(contents.map(\.lastPathComponent))
        #expect(names.contains("photo1.jpg"))
        #expect(names.contains("photo2.jpg"))
        #expect(names.count == 2)
    }

    @Test("second call returns existing fork path without re-copying")
    func testForkReturnsExistingPath() async throws {
        let baseDir = try makeTempDir()
        let sourceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        try createTestImage(at: sourceDir, name: "photo1.jpg")

        let manager = ForkManager(baseURL: baseDir)
        let first = try await manager.getOrCreateFork(
            pluginId: "test-plugin",
            sourceURL: sourceDir
        )
        let second = try await manager.getOrCreateFork(
            pluginId: "test-plugin",
            sourceURL: sourceDir
        )

        #expect(first == second)
    }

    @Test("resolveSource returns main URL when no dependencies have forks")
    func testResolveSourceFromMain() async throws {
        let baseDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let mainURL = URL(fileURLWithPath: "/tmp/main")
        let manager = ForkManager(baseURL: baseDir)

        let resolved = await manager.resolveSource(
            pluginId: "plugin-a",
            dependencies: ["plugin-b"],
            executedPlugins: [("import", "plugin-b")],
            mainURL: mainURL
        )

        #expect(resolved == mainURL)
    }

    @Test("resolveSource returns dependency fork URL when dependency was forked")
    func testResolveSourceFromDependency() async throws {
        let baseDir = try makeTempDir()
        let sourceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        try createTestImage(at: sourceDir, name: "photo1.jpg")

        let mainURL = URL(fileURLWithPath: "/tmp/main")
        let manager = ForkManager(baseURL: baseDir)

        let depForkURL = try await manager.getOrCreateFork(
            pluginId: "plugin-b",
            sourceURL: sourceDir
        )

        let resolved = await manager.resolveSource(
            pluginId: "plugin-a",
            dependencies: ["plugin-b"],
            executedPlugins: [("import", "plugin-b")],
            mainURL: mainURL
        )

        #expect(resolved == depForkURL)
    }

    @Test("writeBack copies fork files to main directory")
    func testWriteBack() async throws {
        let baseDir = try makeTempDir()
        let sourceDir = try makeTempDir()
        let mainDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: mainDir)
        }

        try createTestImage(at: sourceDir, name: "photo1.jpg")

        let manager = ForkManager(baseURL: baseDir)
        let forkURL = try await manager.getOrCreateFork(
            pluginId: "test-plugin",
            sourceURL: sourceDir
        )

        // Verify file is in fork
        #expect(FileManager.default.fileExists(
            atPath: forkURL.appendingPathComponent("photo1.jpg").path
        ))

        try await manager.writeBack(pluginId: "test-plugin", mainURL: mainDir)

        #expect(FileManager.default.fileExists(
            atPath: mainDir.appendingPathComponent("photo1.jpg").path
        ))
    }
}
