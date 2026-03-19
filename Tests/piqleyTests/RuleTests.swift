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
                "field": "original:TIFF:Model",
                "pattern": "regex:.*a7r.*"
            },
            "emit": [
                {
                    "field": "keywords",
                    "values": ["sony", "mirrorless"]
                }
            ]
        }
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.match.field == "original:TIFF:Model")
        #expect(rule.match.pattern == "regex:.*a7r.*")
        #expect(rule.emit[0].field == "keywords")
        #expect(rule.emit[0].values == ["sony", "mirrorless"])
    }

    @Test("rule with only required fields decodes")
    func omittedOptionals() throws {
        let json = """
        {
            "match": {
                "field": "original:IPTC:Keywords",
                "pattern": "landscape"
            },
            "emit": [
                {
                    "field": "keywords",
                    "values": ["nature"]
                }
            ]
        }
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.emit[0].field == "keywords")
        #expect(rule.match.field == "original:IPTC:Keywords")
        #expect(rule.emit[0].values == ["nature"])
    }
}
