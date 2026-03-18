import PiqleyCore

extension HookConfig {
    func makeEvaluator() -> ExitCodeEvaluator {
        ExitCodeEvaluator(
            successCodes: successCodes,
            warningCodes: warningCodes,
            criticalCodes: criticalCodes
        )
    }
}
