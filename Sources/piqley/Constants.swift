import Foundation

enum AppConstants {
    static let name = "piqley"
    static let version = "1.0.0"
    static let userAgent = "Piqley/\(version) (+https://github.com/josephquigley/piqley)"

    /// Dot-prefixed name for hidden result files (e.g. ".piqley-failure.txt")
    static var resultFilePrefix: String { ".\(name)" }
}
