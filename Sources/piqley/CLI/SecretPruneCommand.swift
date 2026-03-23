import ArgumentParser
import Foundation

extension SecretCommand {
    struct PruneCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove orphaned secrets not referenced by any config or workflow"
        )

        func run() throws {
            let configStore = BasePluginConfigStore.default
            let secretStore = makeDefaultSecretStore()

            let pruned = try SecretPruner.prune(
                configStore: configStore,
                secretStore: secretStore
            )

            if pruned.isEmpty {
                print("No orphaned secrets found.")
            } else {
                for alias in pruned {
                    print("Pruned: \(alias)")
                }
                print("\(pruned.count) orphaned secret(s) removed.")
            }
        }
    }
}
