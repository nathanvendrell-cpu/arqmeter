import Foundation

/// Official daily buckets are history, not a live token stream. One shared
/// reader refreshes at a UTC day change; failed reads retain the hourly backoff.
enum OfficialDailyRefreshPolicy {
    static func shouldRefresh(lastAttempt: Date?, succeeded: Bool, now: Date,
                              quotaRecovered: Bool = false) -> Bool {
        guard let lastAttempt else { return true }
        let age = now.timeIntervalSince(lastAttempt)
        if age < 0 { return true }
        if !succeeded { return quotaRecovered || age >= 3600 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return !calendar.isDate(lastAttempt, inSameDayAs: now)
    }
}

enum OfficialDailyRefreshSelfTest {
    static func run() throws {
        let day = Date(timeIntervalSince1970: 1_789_948_800)
        let last = day.addingTimeInterval(15 * 3600)
        func check(_ value: Bool, _ code: Int) throws {
            if !value { throw NSError(domain: "OfficialDailyRefreshPolicy", code: code) }
        }
        try check(OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: nil, succeeded: false, now: day), 1)
        try check(!OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: true,
                                                            now: day.addingTimeInterval(23 * 3600)), 2)
        try check(OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: true,
                                                           now: day.addingTimeInterval(24 * 3600)), 3)
        try check(!OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: false,
                                                            now: last.addingTimeInterval(3599)), 4)
        try check(OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: false,
                                                           now: last.addingTimeInterval(3600)), 5)
        try check(OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: false,
                                                           now: last.addingTimeInterval(30), quotaRecovered: true), 6)
        try check(OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: last, succeeded: true,
                                                           now: last.addingTimeInterval(-60)), 7)
    }
}
