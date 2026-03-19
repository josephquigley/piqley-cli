import Foundation
import Logging
import PiqleyCore

/// Per-plugin-execution buffer for lazy metadata extraction and batched write-back.
/// Each plugin execution gets its own fresh instance.
actor MetadataBuffer {
    private var metadata: [String: [String: JSONValue]] = [:]
    private var dirty: Set<String> = []
    private let imageURLs: [String: URL]
    private let logger = Logger(label: "piqley.metadata-buffer")

    init(imageURLs: [String: URL]) {
        self.imageURLs = imageURLs
    }

    /// Load metadata for an image. Extracts from disk on first call, returns cached on subsequent.
    func load(image: String) -> [String: JSONValue] {
        if let cached = metadata[image] {
            return cached
        }

        guard let url = imageURLs[image] else {
            return [:]
        }

        let extracted = MetadataExtractor.extract(from: url)
        metadata[image] = extracted
        return extracted
    }

    /// Apply a pre-compiled write action against an image's metadata.
    func applyAction(_ action: EmitAction, image: String) {
        if metadata[image] == nil {
            _ = load(image: image)
        }

        var current = metadata[image] ?? [:]
        RuleEvaluator.applyAction(action, to: &current)
        metadata[image] = current
        dirty.insert(image)
    }

    /// Flush all dirty images to disk. Errors are logged, not thrown.
    func flush() {
        for imageName in dirty {
            guard let url = imageURLs[imageName],
                  let imageMetadata = metadata[imageName]
            else { continue }

            do {
                try MetadataWriter.write(metadata: imageMetadata, to: url)
            } catch {
                logger.error("Failed to write metadata for \(imageName): \(error.localizedDescription)")
            }
        }
        dirty.removeAll()
    }

    /// Clear all cached metadata. Call after a binary may have modified files on disk.
    /// The dirty set should already be empty (flushed before binary execution).
    func invalidateAll() {
        metadata.removeAll()
    }
}
