import Foundation
import Logging
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

        let smtp = SMTP(
            hostname: config.host,
            email: config.username,
            password: password,
            port: Int32(config.port),
            tlsMode: .requireSTARTTLS
        )

        let from = Mail.User(email: config.from)
        let toUser = Mail.User(email: to)

        let attachment = Attachment(
            filePath: attachmentPath,
            mime: "image/jpeg",
            name: attachmentFilename
        )

        let mail = Mail(
            from: from,
            to: [toUser],
            subject: subject,
            text: body,
            attachments: [attachment]
        )

        var sendError: Error?
        smtp.send(mail) { error in
            sendError = error
        }

        if let error = sendError {
            throw EmailSenderError.sendFailed(error.localizedDescription)
        }

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
