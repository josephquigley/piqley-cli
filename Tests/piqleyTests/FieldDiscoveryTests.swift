import Testing
import PiqleyCore
@testable import piqley

@Suite("FieldDiscovery")
struct FieldDiscoveryTests {

    // MARK: - original source

    @Test("original key contains fields from catalog")
    func originalKeyContainsFields() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let originalFields = result["original"]
        #expect(originalFields != nil)
        #expect(originalFields?.isEmpty == false)
    }

    // MARK: - read source

    @Test("read key is present and non-empty")
    func readKeyPresent() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let readFields = result["read"]
        #expect(readFields != nil)
        #expect(readFields?.isEmpty == false)
    }

    // MARK: - dependency fields

    @Test("dependency plugin fields appear under plugin identifier key")
    func dependencyFieldsKeyedByIdentifier() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.myplugin",
            fields: ["AlbumName", "CameraSerial"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let depFields = result["com.example.myplugin"]
        #expect(depFields != nil)
        #expect(depFields?.count == 2)
    }

    @Test("dependency fields have custom category")
    func dependencyFieldsAreCustomCategory() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "exif-tagger",
            fields: ["scene"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let field = result["exif-tagger"]?.first
        #expect(field?.category == .custom)
        #expect(field?.source == "exif-tagger")
    }

    @Test("dependency fields are sorted alphabetically")
    func dependencyFieldsSortedAlphabetically() {
        let dep = FieldDiscovery.DependencyInfo(
            identifier: "com.example.plugin",
            fields: ["Zebra", "Alpha", "Middle"]
        )
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        let names = result["com.example.plugin"]?.map(\.name) ?? []
        #expect(names == ["Alpha", "Middle", "Zebra"])
    }

    @Test("multiple dependencies each get their own key")
    func multipleDependenciesEachGetOwnKey() {
        let dep1 = FieldDiscovery.DependencyInfo(identifier: "plugin.a", fields: ["FieldA"])
        let dep2 = FieldDiscovery.DependencyInfo(identifier: "plugin.b", fields: ["FieldB"])
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep1, dep2])
        #expect(result["plugin.a"] != nil)
        #expect(result["plugin.b"] != nil)
    }

    @Test("result always contains original and read keys")
    func alwaysContainsOriginalAndRead() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        #expect(result.keys.contains("original"))
        #expect(result.keys.contains("read"))
    }

    @Test("no dependencies: result has exactly two keys")
    func noDependenciesResultHasTwoKeys() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        #expect(result.count == 2)
    }
}
