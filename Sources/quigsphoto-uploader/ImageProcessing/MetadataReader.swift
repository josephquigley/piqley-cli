import Foundation

protocol MetadataReader {
    func read(from path: String) throws -> ImageMetadata
}
