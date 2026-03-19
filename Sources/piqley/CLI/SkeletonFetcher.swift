import Foundation

enum SkeletonFetcher {
    /// Validate the target directory is empty or does not exist.
    static func validateTargetDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            throw CreateError.targetNotEmpty(url.path)
        }
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        if !contents.isEmpty {
            throw CreateError.targetNotEmpty(url.path)
        }
    }

    /// Download and extract the SDK tarball, returning the path to the skeleton directory.
    static func fetchAndExtractSkeleton(
        repoURL: String, tag: SemVer, language: String
    ) throws -> (skeletonDir: URL, tempDir: URL) {
        let tagString = "v\(tag.versionString)"
        let tarballURL = "\(repoURL)/archive/refs/tags/\(tagString).tar.gz"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tarballPath = tempDir.appendingPathComponent("sdk.tar.gz")

        // Download tarball
        let curlProcess = Process()
        curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        curlProcess.arguments = ["curl", "-sL", "-o", tarballPath.path, tarballURL]
        curlProcess.standardError = FileHandle.nullDevice
        try curlProcess.run()
        curlProcess.waitUntilExit()

        guard curlProcess.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tarballPath.path)
        else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.tarballDownloadFailed(tarballURL)
        }

        // Extract tarball
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tarProcess.arguments = ["tar", "xzf", tarballPath.path, "-C", extractDir.path]
        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.extractionFailed("tar exited with code \(tarProcess.terminationStatus)")
        }

        // Find the single top-level directory inside the extracted contents
        let extractedContents = try FileManager.default.contentsOfDirectory(
            at: extractDir, includingPropertiesForKeys: nil
        )
        guard let topLevel = extractedContents.first(where: {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.extractionFailed("No top-level directory found in archive")
        }

        let langLower = language.lowercased()
        let skeletonDir = topLevel.appendingPathComponent("Skeletons/\(langLower)")

        var isDirCheck: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skeletonDir.path, isDirectory: &isDirCheck),
              isDirCheck.boolValue
        else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.skeletonNotFound(langLower, tag.versionString)
        }

        return (skeletonDir, tempDir)
    }

    /// Copy skeleton contents to the target directory.
    static func copySkeleton(from skeletonDir: URL, to targetDir: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let items = try fileManager.contentsOfDirectory(at: skeletonDir, includingPropertiesForKeys: nil)
        for item in items {
            let dest = targetDir.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: dest)
        }
    }

    /// Replace `__PLUGIN_NAME__` and `__SDK_VERSION__` in all files under a directory.
    static func applyTemplateSubstitutions(
        in directory: URL, pluginName: String, sdkVersion: String
    ) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let replaced = content
                .replacingOccurrences(of: "__PLUGIN_NAME__", with: pluginName)
                .replacingOccurrences(of: "__SDK_VERSION__", with: sdkVersion)

            if replaced != content {
                try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
