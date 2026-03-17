import Foundation
import Logging
import NIO
import SwiftSMTP

struct EmailSender {
    private let config: AppConfig.SMTPConfig
    private let secretStore: SecretStore
    private let logger = Logger(label: "\(AppConstants.loggerPrefix).email")

    init(config: AppConfig.SMTPConfig, secretStore: SecretStore) {
        self.config = config
        self.secretStore = secretStore
    }

    func send(
        to: String,
        subject: String,
        body: String,
        attachmentPath: String,
        attachmentFilename: String
    ) throws {
        let password = try secretStore.get(key: "\(AppConstants.keychainServicePrefix)-smtp")

        let smtpConfig = Configuration(
            server: .init(
                hostname: config.host,
                port: config.port,
                encryption: .startTLS(.always)
            ),
            credentials: .init(username: config.username, password: password),
            featureFlags: [.useESMTP]
        )

        let imageData = try Data(contentsOf: URL(fileURLWithPath: attachmentPath))

        let email = Email(
            sender: .init(emailAddress: config.from),
            recipients: [.init(emailAddress: to)],
            subject: subject,
            body: .plain(body),
            attachments: [
                .init(
                    name: attachmentFilename,
                    contentType: "image/jpeg",
                    data: imageData
                )
            ]
        )

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }

        let mailer = Mailer(group: eventLoopGroup, configuration: smtpConfig)

        let future = mailer.send(email)
        try future.wait()

        logger.info("Email sent to \(to): \(subject)")
    }
}

enum EmailSenderError: Error, LocalizedError {
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): return "Email send failed: \(msg)"
        }
    }
}
