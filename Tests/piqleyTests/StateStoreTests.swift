import Testing
import Foundation
@testable import piqley

@Suite("StateStore")
struct StateStoreTests {
    @Test("setNamespace stores values and resolve returns them")
    func testSetAndResolve() async {
        let store = StateStore()
        await store.setNamespace(
            image: "IMG_001.jpg",
            plugin: "hashtag",
            values: ["tags": .array([.string("#cat"), .string("#dog")])]
        )
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"]?["tags"] == .array([.string("#cat"), .string("#dog")]))
    }

    @Test("resolve returns empty dict for unknown dependencies")
    func testResolveUnknownDependency() async {
        let store = StateStore()
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["nonexistent"])
        #expect(resolved["nonexistent"] == nil)
    }

    @Test("resolve filters to only requested dependencies")
    func testResolveFilters() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_001.jpg", plugin: "watermark", values: ["b": .string("2")])
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"] != nil)
        #expect(resolved["watermark"] == nil)
    }

    @Test("setNamespace replaces previous values for same plugin+image")
    func testReplaceNamespace() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["old": .string("v1")])
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["new": .string("v2")])
        let resolved = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        #expect(resolved["hashtag"]?["old"] == nil)
        #expect(resolved["hashtag"]?["new"] == .string("v2"))
    }

    @Test("different images have independent state")
    func testPerImageIsolation() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "hashtag", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_002.jpg", plugin: "hashtag", values: ["a": .string("2")])
        let r1 = await store.resolve(image: "IMG_001.jpg", dependencies: ["hashtag"])
        let r2 = await store.resolve(image: "IMG_002.jpg", dependencies: ["hashtag"])
        #expect(r1["hashtag"]?["a"] == .string("1"))
        #expect(r2["hashtag"]?["a"] == .string("2"))
    }

    @Test("allImageNames returns all images with state")
    func testAllImageNames() async {
        let store = StateStore()
        await store.setNamespace(image: "IMG_001.jpg", plugin: "original", values: ["a": .string("1")])
        await store.setNamespace(image: "IMG_002.jpg", plugin: "original", values: ["b": .string("2")])
        let names = await store.allImageNames
        #expect(names.sorted() == ["IMG_001.jpg", "IMG_002.jpg"])
    }
}
