import XCTest
@testable import piqley

final class GhostSchedulerTests: XCTestCase {
    func testRandomTimeInWindow() {
        let window = AppConfig.GhostConfig.SchedulingWindow(start: "08:00", end: "10:00", timezone: "America/New_York")
        for _ in 0..<20 {
            let (hour, minute) = GhostScheduler.randomTimeInWindow(window)
            let totalMinutes = hour * 60 + minute
            XCTAssertGreaterThanOrEqual(totalMinutes, 8 * 60)
            XCTAssertLessThan(totalMinutes, 10 * 60)
        }
    }

    func testFormatScheduleDate() {
        let components = DateComponents(timeZone: TimeZone(identifier: "America/New_York"), year: 2026, month: 3, day: 20, hour: 9, minute: 15)
        let date = Calendar.current.date(from: components)!
        let formatted = GhostScheduler.formatForGhost(date: date)
        XCTAssertTrue(formatted.contains("2026-03-20"))
    }

    func testDay365Calculation() {
        let refDate = "2025-12-25"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let day1 = formatter.date(from: "2025:12:26 10:00:00")!
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: day1, referenceDate: refDate), 2)

        let day10 = formatter.date(from: "2026:01:03 10:00:00")!
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: day10, referenceDate: refDate), 10)

        let refDay = formatter.date(from: "2025:12:25 10:00:00")!
        XCTAssertEqual(GhostScheduler.calculate365DayNumber(photoDate: refDay, referenceDate: refDate), 1)
    }

    func testDay365BeforeReferenceDate() {
        let refDate = "2025-12-25"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let beforeRef = formatter.date(from: "2025:12:20 10:00:00")!
        let dayNum = GhostScheduler.calculate365DayNumber(photoDate: beforeRef, referenceDate: refDate)
        XCTAssertEqual(dayNum, 6)
    }
}
