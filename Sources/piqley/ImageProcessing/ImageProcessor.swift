import Foundation

protocol ImageProcessor {
    func process(
        inputPath: String, outputPath: String,
        maxLongEdge: Int, jpegQuality: Int, metadataAllowlist: [String]
    ) throws
}
