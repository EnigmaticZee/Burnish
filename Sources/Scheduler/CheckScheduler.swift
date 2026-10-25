import Foundation

/// Runs a check on a schedule with `NSBackgroundActivityScheduler`, so macOS can pick a moment
/// that suits power and load. Also catches up on launch when a check is overdue.
public final class CheckScheduler: @unchecked Sendable {
    public typealias Work = @Sendable () async -> Void

    private let identifier: String
    private let lock = NSLock()
    private var activity: NSBackgroundActivityScheduler?

    public init(identifier: String = "io.github.enigmaticzee.Burnish.check") {
        self.identifier = identifier
    }

    /// Schedules `work` every `interval`. Nil interval stops the schedule ("Only when I ask").
    public func schedule(every interval: TimeInterval?, work: @escaping Work) {
        lock.withLock {
            activity?.invalidate()
            activity = nil
            guard let interval else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
            scheduler.repeats = true
            scheduler.interval = interval
            scheduler.tolerance = min(interval * 0.1, 3600)
            scheduler.qualityOfService = .utility
            scheduler.schedule { completion in
                Task {
                    await work()
                    completion(.finished)
                }
            }
            activity = scheduler
        }
    }

    /// True when the last check is older than the interval (or there wasn't one).
    public static func isOverdue(lastCheck: Date?, interval: TimeInterval?, now: Date = Date()) -> Bool {
        guard let interval else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// At most one notification a day: true when the last one was on an earlier calendar day.
    public static func mayNotify(lastNotification: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let lastNotification else { return true }
        return !calendar.isDate(lastNotification, inSameDayAs: now) && now > lastNotification
    }
}
