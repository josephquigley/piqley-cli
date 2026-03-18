import Testing
@testable import piqley

@Suite("PluginBlocklist")
struct PluginBlocklistTests {
    @Test("freshly created blocklist has no blocked plugins")
    func testEmpty() {
        let blocklist = PluginBlocklist()
        #expect(blocklist.isBlocked("ghost") == false)
    }

    @Test("blocking a plugin marks it as blocked")
    func testBlock() {
        let blocklist = PluginBlocklist()
        blocklist.block("ghost")
        #expect(blocklist.isBlocked("ghost") == true)
    }

    @Test("blocking does not affect other plugins")
    func testIsolation() {
        let blocklist = PluginBlocklist()
        blocklist.block("ghost")
        #expect(blocklist.isBlocked("365-project") == false)
    }

    @Test("can block multiple plugins")
    func testMultiple() {
        let blocklist = PluginBlocklist()
        blocklist.block("ghost")
        blocklist.block("365-project")
        #expect(blocklist.isBlocked("ghost") == true)
        #expect(blocklist.isBlocked("365-project") == true)
    }
}
