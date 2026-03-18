import Foundation
import Logging

struct GhostScheduler {
    private let client: GhostClient
    private let config: AppConfig.GhostConfig
    private let logger = Logger(label: "\(AppConstants.name).scheduler")

    init(client: GhostClient, config: AppConfig.GhostConfig) {
        self.client = client
        self.config = config
    }

    func nextScheduleDate(is365Project: Bool, project365Keyword: String) async throws -> Date {
        let filter: String
        if is365Project {
            filter = "tag:'\(project365Keyword)'"
        } else {
            var parts = config.non365ProjectFilterTags.map { "tag:'\($0)'" }
            parts.append("tag:-'\(project365Keyword)'")
            filter = parts.joined(separator: "+")
        }
        let scheduled = try await client.getPosts(status: "scheduled", filter: filter, limit: 50)
        if !scheduled.posts.isEmpty {
            let formatter = ISO8601DateFormatter()
            let dates = scheduled.posts.compactMap { post -> Date? in
                guard let dateStr = post.publishedAt else { return nil }
                return formatter.date(from: dateStr)
            }
            if let maxDate = dates.max() {
                return Calendar.current.date(byAdding: .day, value: 1, to: maxDate)!
            }
        }
        let published = try await client.getPosts(status: "published", filter: filter, limit: 1)
        if let latestPost = published.posts.first,
           let dateStr = latestPost.publishedAt,
           let pubDate = ISO8601DateFormatter().date(from: dateStr)
        {
            if Calendar.current.isDateInToday(pubDate) {
                return Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            }
        }
        return Date()
    }

    func buildScheduleDateTime(baseDate: Date) -> Date {
        let (hour, minute) = Self.randomTimeInWindow(config.schedulingWindow)
        guard let timeZone = TimeZone(identifier: config.schedulingWindow.timezone) else { return baseDate }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let scheduled = calendar.date(from: components) else { return baseDate }
        // If the scheduled time is in the past, bump to tomorrow
        if scheduled <= Date() {
            return calendar.date(byAdding: .day, value: 1, to: scheduled) ?? scheduled
        }
        return scheduled
    }

    static func randomTimeInWindow(_ window: AppConfig.GhostConfig.SchedulingWindow) -> (hour: Int, minute: Int) {
        let startParts = window.start.split(separator: ":").map { Int($0)! }
        let endParts = window.end.split(separator: ":").map { Int($0)! }
        let startMinutes = startParts[0] * 60 + startParts[1]
        let endMinutes = endParts[0] * 60 + endParts[1]
        let randomMinutes = Int.random(in: startMinutes ..< endMinutes)
        return (hour: randomMinutes / 60, minute: randomMinutes % 60)
    }

    static func formatForGhost(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func calculate365DayNumber(photoDate: Date, referenceDate: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let refDate = formatter.date(from: referenceDate) else { return 1 }
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: refDate), to: calendar.startOfDay(for: photoDate)
        )
        let days = components.day ?? 0
        return abs(days) + 1
    }
}
