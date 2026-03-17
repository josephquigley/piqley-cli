import ArgumentParser
import Foundation
import Logging

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process all images in a folder and publish to Ghost CMS"
    )

    @Argument(help: "Path to folder containing exported images")
    var folderPath: String

    @Flag(help: "Preview actions without uploading or emailing")
    var dryRun = false

    @Flag(help: "Include successful images in result output")
    var verboseResults = false

    @Flag(help: "Write a single JSON results file instead of individual text files")
    var jsonResults = false

    @Option(help: "Directory to write result files to (default: input folder)")
    var resultsDir: String?

    func run() async throws {
        let logger = Logger(label: "\(AppConstants.loggerPrefix).process")

        // Load config
        guard FileManager.default.fileExists(atPath: AppConfig.configPath.path) else {
            logger.error("Config not found. Run `\(AppConstants.binaryName) setup` first.")
            throw ExitCode(1)
        }
        let config = try AppConfig.load(from: AppConfig.configPath.path)

        // Build tag matchers from blocklist
        let tagMatchers: [TagMatcher]
        do {
            tagMatchers = try TagMatcherFactory.buildMatchers(from: config.tagBlocklist)
        } catch {
            logger.error("Invalid blocklist pattern: \(error)")
            throw ExitCode(1)
        }

        // Build camera tag matchers
        let cameraTagMatchers: [(TagMatcher, [String])]
        do {
            cameraTagMatchers = try config.cameraModelTags.map { (key, tags) in
                let matcher = try TagMatcherFactory.buildMatchers(from: [key]).first!
                return (matcher, tags)
            }
        } catch {
            logger.error("Invalid cameraTags pattern: \(error)")
            throw ExitCode(1)
        }

        // Acquire lock
        let lockPath = NSTemporaryDirectory() + "\(AppConstants.tempDirectoryName)/\(AppConstants.binaryName).lock"
        let lock: ProcessLock
        do {
            lock = try ProcessLock(path: lockPath)
        } catch ProcessLockError.alreadyRunning {
            logger.error("Another instance of \(AppConstants.binaryName) is already running.")
            throw ExitCode(1)
        }
        defer { lock.release() }

        // Create temp directory for resized images (separate from lock dir)
        let tempDir = NSTemporaryDirectory() + "\(AppConstants.tempDirectoryName)/images/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        // Initialize components
        let secretStore = KeychainSecretStore()
        let ghostAPIKey = try secretStore.get(key: "\(AppConstants.keychainServicePrefix)-ghost")
        let ghostClient = GhostClient(baseURL: config.ghost.url, apiKey: ghostAPIKey)
        let metadataReader = CGImageMetadataReader()
        let imageProcessor = CoreGraphicsImageProcessor()
        let scanner = ImageScanner(metadataReader: metadataReader)
        let uploadLog = UploadLog(path: AppConfig.configDirectory.appendingPathComponent("upload-log.jsonl").path)
        let emailLog = EmailLog(path: AppConfig.configDirectory.appendingPathComponent("email-log.jsonl").path)
        let deduplicator = GhostDeduplicator(uploadLog: uploadLog, client: ghostClient)
        let scheduler = GhostScheduler(client: ghostClient, config: config.ghost)

        // Log helper: print for dry run, logger.info for normal
        let log: (String) -> Void = dryRun ? { print($0) } : { logger.info("\($0)") }

        // Seed email log from Ghost if it doesn't exist
        if !emailLog.fileExists {
            log("Email log not found — seeding from Ghost...")
            await seedEmailLog(emailLog: emailLog, client: ghostClient, config: config)
        }

        // Scan and sort images
        log("Scanning folder: \(folderPath)")
        let images = try scanner.scan(folder: folderPath)
        log("Found \(images.count) images")

        var results = ProcessingResults()
        var emailCandidates: [(image: ScannedImage, resizedPath: String, emailSubject: String)] = []

        // Process each image
        for image in images {
            do {
                let processedKeywords: [String]
                if dryRun {
                    let filterResult = ImageMetadata.filterKeywords(
                        image.metadata.keywords,
                        blocklist: tagMatchers
                    )
                    processedKeywords = filterResult.kept
                    let allLeaves = image.metadata.keywords.map { ImageMetadata.leafKeyword($0) }
                    print("[\(image.filename)] Keywords: \(allLeaves.joined(separator: ", "))")
                    if !filterResult.blocked.isEmpty {
                        let blockedDesc = filterResult.blocked.map { "\($0.keyword) (\($0.matcher))" }
                        print("[\(image.filename)] Blocked: \(blockedDesc.joined(separator: ", "))")
                    }
                } else {
                    processedKeywords = ImageMetadata.processKeywords(
                        image.metadata.keywords,
                        blocklist: tagMatchers
                    )
                }
                let is365 = image.metadata.is365Project(keyword: config.project365.keyword)

                // Compute post title early (needed for email subject on dedup path)
                let hasTitle: Bool
                let postTitle: String
                let emailSubject: String
                if is365 {
                    let dayNumber = GhostScheduler.calculate365DayNumber(
                        photoDate: image.metadata.dateTimeOriginal ?? Date(),
                        referenceDate: config.project365.referenceDate
                    )
                    postTitle = "365 Project #\(dayNumber)"
                    emailSubject = image.metadata.title ?? "Day \(dayNumber)"
                    hasTitle = true
                } else {
                    if let title = image.metadata.title {
                        postTitle = title
                        hasTitle = true
                    } else {
                        postTitle = image.filename
                        hasTitle = false
                    }
                    emailSubject = postTitle
                }

                // Dedup check (Ghost API failure is fatal — let GhostDeduplicatorError propagate)
                let isDup: Bool
                do {
                    isDup = try await deduplicator.isDuplicate(filename: image.filename)
                } catch is GhostDeduplicatorError {
                    logger.error("Fatal: Ghost API dedup query failed — aborting to avoid duplicates")
                    throw ExitCode(1)
                }
                if isDup {
                    if dryRun {
                        print("[\(image.filename)] Duplicate — skipping")
                    } else {
                        logger.info("[\(image.filename)] Duplicate — skipping")
                    }
                    results.duplicates.append(image.filename)
                    if !dryRun {
                        // Still check email for 365 Project
                        if is365 {
                            let resizedPath = tempDir + image.filename
                            if !FileManager.default.fileExists(atPath: resizedPath) {
                                try imageProcessor.process(
                                    inputPath: image.path,
                                    outputPath: resizedPath,
                                    maxLongEdge: config.processing.maxLongEdge,
                                    jpegQuality: config.processing.jpegQuality
                                )
                            }
                            emailCandidates.append((image: image, resizedPath: resizedPath, emailSubject: emailSubject))
                        }
                    }
                    continue
                }

                // Resize image
                let resizedPath = tempDir + image.filename
                if !dryRun {
                    logger.info("[\(image.filename)] Resizing...")
                    try imageProcessor.process(
                        inputPath: image.path,
                        outputPath: resizedPath,
                        maxLongEdge: config.processing.maxLongEdge,
                        jpegQuality: config.processing.jpegQuality
                    )
                }


                // Build tags
                var tags: [GhostTagInput] = []
                if is365 {
                    tags.append(GhostTagInput(name: config.project365.keyword))
                }
                for keyword in processedKeywords where keyword != config.project365.keyword {
                    tags.append(GhostTagInput(name: keyword))
                }
                let cameraTags = image.metadata.matchingCameraTags(from: config.cameraModelTags, matchers: cameraTagMatchers)
                for tag in cameraTags {
                    tags.append(GhostTagInput(name: tag))
                }
                if dryRun && !cameraTags.isEmpty {
                    print("[\(image.filename)] Camera tags (\(image.metadata.cameraModel ?? "unknown")): \(cameraTags.joined(separator: ", "))")
                }
                for tag in config.requiredTags {
                    tags.append(GhostTagInput(name: tag))
                }

                // De-duplicate tags (case-insensitive, preserving first occurrence)
                var seen = Set<String>()
                tags = tags.filter { seen.insert($0.name.lowercased()).inserted }

                // Build body
                let bodyTitle = is365 ? image.metadata.title : nil
                let bodyDescription = image.metadata.description
                let status = hasTitle ? "scheduled" : "draft"

                if dryRun {
                    if status == "scheduled" {
                        let scheduleDate = try await scheduler.nextScheduleDate(is365Project: is365, project365Keyword: config.project365.keyword)
                        let dateTime = scheduler.buildScheduleDateTime(baseDate: scheduleDate)
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd HH:mm"
                        formatter.timeZone = TimeZone(identifier: config.ghost.schedulingWindow.timezone) ?? .current
                        let formatted = formatter.string(from: dateTime)
                        print("[\(image.filename)] Would schedule: \"\(postTitle)\" on \(formatted) \(config.ghost.schedulingWindow.timezone)")
                        results.scheduled.append(image.filename)
                    } else {
                        print("[\(image.filename)] Would save as draft: \"\(postTitle)\"")
                        results.drafts.append(image.filename)
                    }
                    results.successes.append(image.filename)
                    continue
                }

                // Upload image to Ghost
                logger.info("[\(image.filename)] Uploading to Ghost...")
                let imageURL = try await ghostClient.uploadImage(filePath: resizedPath, filename: image.filename)

                // Build Lexical content
                let lexical = LexicalBuilder.build(
                    title: bodyTitle,
                    description: bodyDescription
                )

                // Build slug with year prefix
                let photoYear: String
                if let date = image.metadata.dateTimeOriginal {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy"
                    photoYear = formatter.string(from: date)
                } else {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy"
                    photoYear = formatter.string(from: Date())
                }
                let slugBase = postTitle.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(.init(charactersIn: "-")))
                let slug = "\(photoYear)-\(slugBase)"

                // Determine schedule date
                var publishedAt: String?
                if hasTitle {
                    let scheduleDate = try await scheduler.nextScheduleDate(is365Project: is365, project365Keyword: config.project365.keyword)
                    let dateTime = scheduler.buildScheduleDateTime(baseDate: scheduleDate)
                    publishedAt = GhostScheduler.formatForGhost(date: dateTime)
                }

                // Create post
                let post = GhostPostCreate(
                    title: postTitle,
                    slug: slug,
                    lexical: lexical,
                    status: status,
                    publishedAt: publishedAt,
                    featureImage: imageURL,
                    tags: tags
                )
                let created = try await ghostClient.createPost(post)
                logger.info("[\(image.filename)] \(status == "scheduled" ? "Scheduled" : "Draft"): \(postTitle) (post \(created.id))")

                if status == "scheduled" {
                    results.scheduled.append(image.filename)
                } else {
                    results.drafts.append(image.filename)
                }

                // Log successful upload
                let logEntry = UploadLogEntry(
                    filename: image.filename,
                    ghostUrl: "\(config.ghost.url)/p/\(created.id)",
                    postId: created.id,
                    timestamp: Date()
                )
                try uploadLog.append(logEntry)

                results.successes.append(image.filename)

                // Add to email candidates if 365 Project and scheduled (not draft)
                if is365 && hasTitle {
                    emailCandidates.append((image: image, resizedPath: resizedPath, emailSubject: emailSubject))
                }

            } catch {
                logger.error("[\(image.filename)] Error: \(error.localizedDescription)")
                results.failures.append(image.filename)
            }
        }

        // Email phase
        if !emailCandidates.isEmpty && !dryRun {
            logger.info("Sending 365 Project emails...")
            let emailSender = EmailSender(config: config.smtp, secretStore: secretStore)

            for candidate in emailCandidates {
                let image = candidate.image
                let resizedPath = candidate.resizedPath
                do {
                    // Email dedup
                    if try emailLog.contains(filename: image.filename) {
                        logger.info("[\(image.filename)] Email already sent — skipping")
                        continue
                    }

                    let subject = candidate.emailSubject
                    let body = image.metadata.description ?? ""

                    try emailSender.send(
                        to: config.project365.emailTo,
                        subject: subject,
                        body: body,
                        attachmentPath: resizedPath,
                        attachmentFilename: image.filename
                    )

                    // Log successful email
                    let entry = EmailLogEntry(
                        filename: image.filename,
                        emailTo: config.project365.emailTo,
                        subject: subject,
                        timestamp: Date()
                    )
                    try emailLog.append(entry)
                    logger.info("[\(image.filename)] Email sent")
                } catch {
                    logger.error("[\(image.filename)] Email error: \(error.localizedDescription)")
                    // Email errors are non-fatal
                }
            }
        }

        // Write results
        let outputDir = resultsDir ?? folderPath
        if jsonResults {
            try ResultsWriter.writeJSON(results: results, to: outputDir, verbose: verboseResults)
        } else {
            try ResultsWriter.writeText(results: results, to: outputDir, verbose: verboseResults)
        }

        // Summary
        let summary = "Processed \(images.count) images: \(results.scheduled.count) scheduled, \(results.drafts.count) drafts, \(results.duplicates.count) duplicates, \(results.failures.count) errors"
        log(summary)

        // Exit code
        if !results.failures.isEmpty {
            throw ExitCode(2)
        }
    }

    private func seedEmailLog(emailLog: EmailLog, client: GhostClient, config: AppConfig) async {
        let logger = Logger(label: "\(AppConstants.loggerPrefix).email-seed")
        do {
            var page = 1
            let cutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60)
            seedLoop: while true {
                let response = try await client.getPosts(
                    status: "published",
                    filter: "tag:'\(config.project365.keyword)'",
                    page: page
                )
                for post in response.posts {
                    if let dateStr = post.publishedAt,
                       let date = ISO8601DateFormatter().date(from: dateStr),
                       date < cutoff { break seedLoop }
                    if let featureImage = post.featureImage,
                       let filename = GhostClient.extractFilename(from: featureImage) {
                        let entry = EmailLogEntry(
                            filename: filename,
                            emailTo: config.project365.emailTo,
                            subject: post.title ?? "",
                            timestamp: Date()
                        )
                        try emailLog.append(entry)
                    }
                }
                guard let meta = response.meta, meta.pagination?.next != nil else { break }
                page += 1
            }
            // Touch the file even if no entries were found, so we don't re-seed every run
            if !emailLog.fileExists {
                FileManager.default.createFile(atPath: emailLog.path, contents: nil)
            }
            logger.info("Email log seeded from Ghost")
        } catch {
            logger.warning("Failed to seed email log: \(error.localizedDescription)")
        }
    }
}
