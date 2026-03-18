import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("Rule")
struct RuleTests {

    @Test("full rule decodes correctly")
    func fullDecode() throws {
        let json = """
        {
            "match": {
                "hook": "pre-process",
                "field": "original:TIFF:Model",
                "pattern": "regex:.*a7r.*"
            },
            "emit": {
                "field": "keywords",
                "values": ["sony", "mirrorless"]
            }
        }
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.match.hook == "pre-process")
        #expect(rule.match.field == "original:TIFF:Model")
        #expect(rule.match.pattern == "regex:.*a7r.*")
        #expect(rule.emit.field == "keywords")
        #expect(rule.emit.values == ["sony", "mirrorless"])
    }

    @Test("omitted hook and emit.field decode as nil")
    func omittedOptionals() throws {
        let json = """
        {
            "match": {
                "field": "original:IPTC:Keywords",
                "pattern": "landscape"
            },
            "emit": {
                "values": ["nature"]
            }
        }
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.match.hook == nil)
        #expect(rule.emit.field == nil)
        #expect(rule.match.field == "original:IPTC:Keywords")
        #expect(rule.emit.values == ["nature"])
    }
}
