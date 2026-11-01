import Foundation

/// Foreground time on one work. A page left on screen stops counting after
/// `idleLimit`, so a reader abandoned on a table cannot report hours of reading.
struct TasteViewingSession: Sendable {
    static let idleLimit: TimeInterval = 120
    static let minimum: TimeInterval = 3
    private(set) var seconds: TimeInterval = 0
    private(set) var pages = Set<Int>()
    private(set) var finished = false
    private var mark: Date?
    private func counted(until date: Date) -> TimeInterval { mark.map { min(Self.idleLimit, max(0, date.timeIntervalSince($0))) } ?? 0 }
    mutating func resume(at date: Date = Date()) { if mark == nil { mark = date } }
    mutating func pause(at date: Date = Date()) { seconds += counted(until: date); mark = nil }
    /// Each page restarts the idle window, so continuous reading is never truncated.
    mutating func show(_ page: Int, isLast: Bool = false, at date: Date = Date()) {
        if mark != nil { seconds += counted(until: date); mark = date }
        pages.insert(page)
        if isLast { finished = true }
    }
    /// Ends the session. Opening a work and leaving at once is not viewing time.
    mutating func finish(at date: Date = Date()) -> TasteDwell? {
        pause(at: date)
        defer { self = .init() }
        guard seconds >= Self.minimum else { return nil }
        return .init(seconds: seconds.rounded(), pages: max(1, pages.count), finished: finished)
    }
}
