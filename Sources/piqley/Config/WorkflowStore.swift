import Foundation

enum WorkflowStore {
    static var workflowsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PiqleyPath.workflows)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: workflowsDirectory,
            withIntermediateDirectories: true
        )
    }

    static func fileURL(name: String) -> URL {
        workflowsDirectory.appendingPathComponent("\(name).json")
    }

    static func exists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(name: name).path)
    }

    static func list() throws -> [String] {
        try ensureDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
            at: workflowsDirectory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static func load(name: String) throws -> Workflow {
        let data = try Data(contentsOf: fileURL(name: name))
        return try JSONDecoder().decode(Workflow.self, from: data)
    }

    static func loadAll() throws -> [Workflow] {
        try list().map { try load(name: $0) }
    }

    static func save(_ workflow: Workflow) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workflow)
        try data.write(to: fileURL(name: workflow.name))
    }

    static func delete(name: String) throws {
        let url = fileURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowError.notFound(name)
        }
        try FileManager.default.removeItem(at: url)
    }

    static func clone(source: String, destination: String) throws {
        guard exists(name: source) else {
            throw WorkflowError.notFound(source)
        }
        guard !exists(name: destination) else {
            throw WorkflowError.alreadyExists(destination)
        }
        var workflow = try load(name: source)
        workflow.name = destination
        workflow.displayName = destination
        try save(workflow)
    }

    /// Seed the default workflow if no workflows exist.
    static func seedDefault(activeStages: [String]) throws {
        try ensureDirectory()
        let existing = try list()
        if existing.isEmpty {
            try save(.empty(name: "default", displayName: "Default", description: "Default workflow", activeStages: activeStages))
        }
    }
}

enum WorkflowError: Error, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)

    var description: String {
        switch self {
        case let .notFound(name): "Workflow '\(name)' not found"
        case let .alreadyExists(name): "Workflow '\(name)' already exists"
        }
    }
}
