import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Refreshes every agent's harvest at 6:00 am Pacific time each day.
///
/// - While the app is open, a timer fires at exactly 6:00 am Pacific.
/// - When the app opens or comes back to the front after a missed 6:00 am, it refreshes right away.
/// - On iPhone and iPad, a background refresh is requested for 6:00 am Pacific; iOS decides the exact moment
///   based on battery, network, and how often the app is used, so it can run somewhat later.
@MainActor
enum DailyRefresh {
    static let hour = 6
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    static let taskID = "com.soofrontier.app.dailyRefresh"

    private static var timer: Task<Void, Never>?

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = pacific
        return c
    }

    /// The most recent 6:00 am Pacific at or before `date` (handles daylight saving through the calendar).
    static func lastRun(before date: Date = .now) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        return today <= date ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }

    static func nextRun(after date: Date = .now) -> Date {
        calendar.date(byAdding: .day, value: 1, to: lastRun(before: date))!
    }

    /// True when the content predates the latest 6:00 am Pacific.
    static func isDue(lastRefresh: Date?) -> Bool {
        (lastRefresh ?? .distantPast) < lastRun()
    }

    /// Call on launch and whenever the app becomes active.
    static func start(_ store: FrontierStore) {
        if isDue(lastRefresh: store.lastRefresh) || store.items.isEmpty {
            Task { await store.refresh() }
        }
        timer?.cancel()
        timer = Task { [weak store] in
            while !Task.isCancelled {
                let wait = max(1, nextRun().timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let store else { return }
                await store.refresh()
            }
        }
        #if os(iOS)
        scheduleBackground()
        #endif
    }

    #if os(iOS)
    /// Registers the background handler; must run before the app finishes launching.
    static func register(_ store: @escaping @MainActor () -> FrontierStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                await store().refresh()
                scheduleBackground()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackground() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = nextRun()
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
