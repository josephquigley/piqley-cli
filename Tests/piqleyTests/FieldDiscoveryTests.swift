import Testing
import PiqleyCore
@testable import piqley

@Suite("FieldDiscovery")
struct FieldDiscoveryTests {

    // MARK: - original source

    @Test("original key contains fields from all MetadataSource cases")
    func originalKeyContainsAllSources() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let originalFields = result["original"]
        #expect(originalFields != nil)
        #expect(originalFields?.isEmpty == false)
        let names = originalFields?.map(\.name) ?? []
        // Should include fields from exif, iptc, xmp, tiff catalogs
        #expect(names.contains("ISO"))           // exif
        #expect(names.contains("Keywords"))      // iptc
        #expect(names.contains("Rating"))        // xmp
        #expect(names.contains("Make"))          // tiff
    }

    @Test("original key count matches sum of all catalog sources")
    func originalKeyCountMatchesCatalogTotal() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let originalFields = result["original"] ?? []
        let expected = MetadataFieldCatalog.fields(forSource: .exif).count
            + MetadataFieldCatalog.fields(forSource: .iptc).count
            + MetadataFieldCatalog.fields(forSource: .xmp).count
            + MetadataFieldCatalog.fields(forSource: .tiff).count
        #expect(originalFields.count == expected)
    }

    // MARK: - read source

    @Test("read key is present and non-empty")
    func readKeyPresent() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let readFields = result["read"]
        #expect(readFields != nil)
        #expect(readFields?.isEmpty == false)
    }

    @Test("read key matches original key fields")
    func readMatchesOriginal() {
        let result = FieldDiscovery.buildAvailableFields(dependencies: [])
        let originalFields = result["original"] ?? []
        let readFields = result["read"] ?? []
        #expect(readFields.count == originalFields.count)
        #expect(readFields.map(\.name) == originalFields.map(\.name))
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
        #expect(result["plugin.a"]?.first?.name == "FieldA")
        #expect(result["plugin.b"]?.first?.name == "FieldB")
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

    @Test("one dependency: result has three keys")
    func oneDependencyResultHasThreeKeys() {
        let dep = FieldDiscovery.DependencyInfo(identifier: "plugin.x", fields: ["F1"])
        let result = FieldDiscovery.buildAvailableFields(dependencies: [dep])
        #expect(result.count == 3)
    }
}
