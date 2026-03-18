import Testing
@testable import piqley

@Suite("ExitCodeEvaluator")
struct ExitCodeEvaluatorTests {
    @Test("all arrays empty: 0 = success, non-zero = critical (Unix defaults)")
    func testUnixDefaults() {
        let eval = ExitCodeEvaluator(successCodes: [], warningCodes: [], criticalCodes: [])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(1) == .critical)
        #expect(eval.evaluate(2) == .critical)
    }

    @Test("explicit successCodes: only those codes are success")
    func testExplicitSuccess() {
        let eval = ExitCodeEvaluator(successCodes: [0, 42], warningCodes: [], criticalCodes: [])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(42) == .success)
        #expect(eval.evaluate(1) == .critical)
    }

    @Test("explicit warningCodes: code in list is warning")
    func testWarning() {
        let eval = ExitCodeEvaluator(successCodes: [0], warningCodes: [2], criticalCodes: [1])
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(2) == .warning)
        #expect(eval.evaluate(1) == .critical)
    }

    @Test("code not in any non-empty list defaults to critical")
    func testUnknownCodeDefaultsToCritical() {
        let eval = ExitCodeEvaluator(successCodes: [0], warningCodes: [2], criticalCodes: [1])
        #expect(eval.evaluate(99) == .critical)
    }

    @Test("nil arrays (absent in manifest) behave identically to empty")
    func testNilBehavesLikeEmpty() {
        let eval = ExitCodeEvaluator(successCodes: nil, warningCodes: nil, criticalCodes: nil)
        #expect(eval.evaluate(0) == .success)
        #expect(eval.evaluate(1) == .critical)
    }
}
