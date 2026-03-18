import Testing
import Foundation
import PiqleyCore
@testable import piqley

@Suite("ConfigEntry")
struct PluginConfigEntryTests {

    @Test("decodes value entry with int default")
    func decodeValueEntryWithDefault() throws {
        let json = #"{"key": "quality", "type": "int", "value": 80}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(key, type, value) = entry else {
            Issue.record("Expected .value, got \(entry)"); return
        }
        #expect(key == "quality")
        #expect(type == .int)
        #expect(value == .number(80))
    }

    @Test("decodes value entry with null value")
    func decodeValueEntryWithNullValue() throws {
        let json = #"{"key": "url", "type": "string", "value": null}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(key, type, value) = entry else {
            Issue.record("Expected .value, got \(entry)"); return
        }
        #expect(key == "url")
        #expect(type == .string)
        #expect(value == .null)
    }

    @Test("decodes value entry with string default")
    func decodeValueEntryWithStringDefault() throws {
        let json = #"{"key": "format", "type": "string", "value": "jpeg"}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(_, _, value) = entry else {
            Issue.record("Expected .value"); return
        }
        #expect(value == .string("jpeg"))
    }

    @Test("decodes value entry with bool default")
    func decodeValueEntryWithBoolDefault() throws {
        let json = #"{"key": "verbose", "type": "bool", "value": true}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .value(_, type, value) = entry else {
            Issue.record("Expected .value"); return
        }
        #expect(type == .bool)
        #expect(value == .bool(true))
    }

    @Test("decodes secret entry")
    func decodeSecretEntry() throws {
        let json = #"{"secret_key": "api-key", "type": "string"}"#
        let entry = try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        guard case let .secret(secretKey, type) = entry else {
            Issue.record("Expected .secret, got \(entry)"); return
        }
        #expect(secretKey == "api-key")
        #expect(type == .string)
    }

    @Test("rejects entry with both key and secret_key")
    func rejectDualEntry() throws {
        let json = #"{"key": "url", "secret_key": "api-key", "type": "string", "value": null}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConfigEntry.self, from: Data(json.utf8))
        }
    }

    @Test("decodes mixed config array")
    func decodeConfigArray() throws {
        let json = #"""
        [
            {"key": "url", "type": "string", "value": null},
            {"key": "quality", "type": "int", "value": 80},
            {"secret_key": "api-key", "type": "string"}
        ]
        """#
        let entries = try JSONDecoder().decode([ConfigEntry].self, from: Data(json.utf8))
        #expect(entries.count == 3)
        if case .value = entries[0] {} else { Issue.record("Expected .value at index 0") }
        if case .value = entries[1] {} else { Issue.record("Expected .value at index 1") }
        if case .secret = entries[2] {} else { Issue.record("Expected .secret at index 2") }
    }

    @Test("decodes setup config with args")
    func decodeSetupConfig() throws {
        let json = #"{"command": "./setup.sh", "args": ["$PIQLEY_SECRET_API_KEY"]}"#
        let config = try JSONDecoder().decode(SetupConfig.self, from: Data(json.utf8))
        #expect(config.command == "./setup.sh")
        #expect(config.args == ["$PIQLEY_SECRET_API_KEY"])
    }

    @Test("decodes setup config without args defaults to empty")
    func decodeSetupConfigNoArgs() throws {
        let json = #"{"command": "./setup.sh"}"#
        let config = try JSONDecoder().decode(SetupConfig.self, from: Data(json.utf8))
        #expect(config.command == "./setup.sh")
        #expect(config.args == [])
    }
}
