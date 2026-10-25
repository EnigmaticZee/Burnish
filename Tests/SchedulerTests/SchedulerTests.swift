import Foundation
import Testing
@testable import Scheduler

@Suite struct SchedulerRules {
    @Test func overdue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CheckScheduler.isOverdue(lastCheck: nil, interval: 86400, now: now))
        #expect(!CheckScheduler.isOverdue(lastCheck: now.addingTimeInterval(-3600), interval: 86400, now: now))
        #expect(CheckScheduler.isOverdue(lastCheck: now.addingTimeInterval(-90000), interval: 86400, now: now))
        #expect(!CheckScheduler.isOverdue(lastCheck: nil, interval: nil, now: now), "manual never runs on its own")
    }

    @Test func oneNotificationADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 21))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 8))!
        #expect(CheckScheduler.mayNotify(lastNotification: nil, now: morning, calendar: calendar))
        #expect(!CheckScheduler.mayNotify(lastNotification: morning, now: evening, calendar: calendar))
        #expect(CheckScheduler.mayNotify(lastNotification: evening, now: tomorrow, calendar: calendar))
    }
}
