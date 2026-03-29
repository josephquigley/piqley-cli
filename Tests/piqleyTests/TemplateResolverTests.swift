import Testing
import Foundation
import Logging
import PiqleyCore
@testable import piqley

@Suite("TemplateResolver")
struct TemplateResolverTests {
    private let logger = Logger(label: "test.template-resolver")
    private let resolver = TemplateResolver()

    @Test("resolves simple field reference")
    func simpleField() async {
        let ctx = TemplateResolver.Context(
            state: ["original": ["EXIF:CameraMake": .string("Canon")]],
            logger: logger
        )
        let result = await resolver.resolve("{{original:EXIF:CameraMake}}", context: ctx)
        #expect(result == "Canon")
    }

    @Test("resolves self namespace to pluginId")
    func selfNamespace() async {
        let ctx = TemplateResolver.Context(
            state: ["com.test.plugin": ["tags": .array([.string("landscape"), .string("sunset")])]],
            pluginId: "com.test.plugin",
            logger: logger
        )
        let result = await resolver.resolve("{{self:tags}}", context: ctx)
        #expect(result == "landscape,sunset")
    }

    @Test("resolves multiple templates in one string")
    func multipleTemplates() async {
        let ctx = TemplateResolver.Context(
            state: [
                "original": [
                    "EXIF:CameraMake": .string("Canon"),
                    "EXIF:LensModel": .string("RF 24-70mm")
                ]
            ],
            logger: logger
        )
        let result = await resolver.resolve(
            "{{original:EXIF:CameraMake}} with {{original:EXIF:LensModel}}",
            context: ctx
        )
        #expect(result == "Canon with RF 24-70mm")
    }

    @Test("missing field resolves to empty string")
    func missingField() async {
        let ctx = TemplateResolver.Context(state: [:], logger: logger)
        let result = await resolver.resolve("{{original:EXIF:Missing}}", context: ctx)
        #expect(result == "")
    }

    @Test("literal string without templates passes through unchanged")
    func literalPassthrough() async {
        let ctx = TemplateResolver.Context(state: [:], logger: logger)
        let result = await resolver.resolve("https://example.com", context: ctx)
        #expect(result == "https://example.com")
    }

    @Test("number values resolve as integers when whole")
    func numberResolution() async {
        let ctx = TemplateResolver.Context(
            state: ["original": ["EXIF:FocalLength": .number(50)]],
            logger: logger
        )
        let result = await resolver.resolve("{{original:EXIF:FocalLength}}", context: ctx)
        #expect(result == "50")
    }

    @Test("bool values resolve correctly")
    func boolResolution() async {
        let ctx = TemplateResolver.Context(
            state: ["original": ["EXIF:Flash": .bool(true)]],
            logger: logger
        )
        let result = await resolver.resolve("{{original:EXIF:Flash}}", context: ctx)
        #expect(result == "true")
    }

    @Test("array values join with commas")
    func arrayJoinsWithCommas() async {
        let ctx = TemplateResolver.Context(
            state: ["original": ["IPTC:Keywords": .array([.string("landscape"), .string("sunset")])]],
            logger: logger
        )
        let result = await resolver.resolve("{{original:IPTC:Keywords}}", context: ctx)
        #expect(result == "landscape,sunset")
    }

    @Test("bare colon-delimited field falls back to plugin namespace")
    func bareFieldFallback() async {
        let ctx = TemplateResolver.Context(
            state: ["com.test.plugin": ["IPTC:Keywords": .array([.string("landscape")])]],
            pluginId: "com.test.plugin",
            logger: logger
        )
        let result = await resolver.resolve("{{IPTC:Keywords}}", context: ctx)
        #expect(result == "landscape")
    }

    @Test("read namespace resolves from MetadataBuffer")
    func readNamespace() async {
        let buffer = MetadataBuffer(preloaded: [
            "test.jpg": ["EXIF:Make": .string("Nikon")]
        ])
        let ctx = TemplateResolver.Context(
            state: [:],
            metadataBuffer: buffer,
            imageName: "test.jpg",
            logger: logger
        )
        let result = await resolver.resolve("{{read:EXIF:Make}}", context: ctx)
        #expect(result == "Nikon")
    }

    @Test("mixed literal and template text")
    func mixedLiteralAndTemplate() async {
        let ctx = TemplateResolver.Context(
            state: ["photo.quigs.datetools": ["365_offset": .string("42")]],
            logger: logger
        )
        let result = await resolver.resolve("365 Project #{{photo.quigs.datetools:365_offset}}", context: ctx)
        #expect(result == "365 Project #42")
    }
}
