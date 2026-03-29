import Foundation

enum TemplateFetcher {
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

    /// Download and extract the SDK tarball, returning the path to the template directory.
    static func fetchAndExtractTemplate(
        repoURL: String, tag: SemVer, language: String
    ) throws -> (templateDir: URL, tempDir: URL) {
        let tarballURL = "\(repoURL)/archive/refs/tags/\(tag.versionString).tar.gz"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tarballPath = tempDir.appendingPathComponent("sdk.tar.gz")

        // Download tarball, capturing the HTTP status code
        let curlProcess = Process()
        let curlStdout = Pipe()
        curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        curlProcess.arguments = [
            "curl", "-sL", "-o", tarballPath.path,
            "-w", "%{http_code}", tarballURL,
        ]
        curlProcess.standardOutput = curlStdout
        curlProcess.standardError = FileHandle.nullDevice
        try curlProcess.run()
        curlProcess.waitUntilExit()

        let httpCode = String(
            data: curlStdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard curlProcess.terminationStatus == 0,
              httpCode == "200",
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
        let templateDir = topLevel.appendingPathComponent("templates/\(langLower)")

        var isDirCheck: ObjCBool = false
        guard FileManager.default.fileExists(atPath: templateDir.path, isDirectory: &isDirCheck),
              isDirCheck.boolValue
        else {
            try? FileManager.default.removeItem(at: tempDir)
            throw CreateError.templateNotFound(langLower, tag.versionString)
        }

        return (templateDir, tempDir)
    }

    /// Copy template contents to the target directory.
    static func copyTemplate(from templateDir: URL, to targetDir: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let items = try fileManager.contentsOfDirectory(at: templateDir, includingPropertiesForKeys: nil)
        for item in items {
            let dest = targetDir.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: dest)
        }
    }

    /// Sanitize a plugin name into a valid Swift package name.
    /// "Ghost & 365 Project Publisher" -> "ghost-365-project-publisher"
    static func sanitizePackageName(_ name: String) -> String {
        let lowered = name.lowercased()
        let sanitized = lowered.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        // Collapse consecutive hyphens and trim leading/trailing hyphens
        let collapsed = sanitized.replacing(/\-{2,}/, with: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Validate that an identifier is in reverse-TLD format (e.g. "com.example.my-plugin").
    /// Must have at least two dot-separated segments, each containing only alphanumerics or hyphens.
    static func validateIdentifier(_ identifier: String) throws {
        let segments = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let validSegment = /^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$/
        guard segments.count >= 2, segments.allSatisfy({ $0.wholeMatch(of: validSegment) != nil }) else {
            throw CreateError.invalidIdentifier(identifier)
        }
    }

    /// Replace template placeholders in all files under a directory.
    static func applyTemplateSubstitutions(
        in directory: URL, pluginName: String, identifier: String, sdkVersion: String
    ) throws {
        let packageName = sanitizePackageName(pluginName)
        let fileManager = FileManager.default

        // Rename directories and files whose names contain placeholders.
        // Process deepest paths first so child renames don't invalidate parent paths.
        try renamePathsContainingPlaceholders(
            in: directory, packageName: packageName, pluginName: pluginName
        )

        // Replace placeholders inside file contents.
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let replaced = content
                .replacingOccurrences(of: "__PLUGIN_PACKAGE_NAME__", with: packageName)
                .replacingOccurrences(of: "__PLUGIN_NAME__", with: pluginName)
                .replacingOccurrences(of: "__PLUGIN_IDENTIFIER__", with: identifier)
                .replacingOccurrences(of: "__SDK_VERSION__", with: sdkVersion)

            if replaced != content {
                try replaced.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Rename any directories or files whose names contain template placeholders.
    private static func renamePathsContainingPlaceholders(
        in directory: URL, packageName: String, pluginName: String
    ) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            return
        }

        // Collect all paths, then sort deepest-first so renames are safe.
        var paths: [URL] = []
        for case let url as URL in enumerator {
            paths.append(url)
        }
        paths.sort { $0.pathComponents.count > $1.pathComponents.count }

        for url in paths {
            let name = url.lastPathComponent
            let renamed = name
                .replacingOccurrences(of: "__PLUGIN_PACKAGE_NAME__", with: packageName)
                .replacingOccurrences(of: "__PLUGIN_NAME__", with: pluginName)
            if renamed != name {
                let dest = url.deletingLastPathComponent().appendingPathComponent(renamed)
                try fileManager.moveItem(at: url, to: dest)
            }
        }
    }
}
