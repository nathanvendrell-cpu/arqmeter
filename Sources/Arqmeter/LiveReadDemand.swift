import Foundation

/// A single existing live reader can serve multiple windows. Closing one window
/// must not stop the reader still needed by another; no extra timers are created.
struct LiveReadDemand {
    private var consumers: Set<String> = []
    var active: Bool { !consumers.isEmpty }
    mutating func acquire(_ consumer: String) { consumers.insert(consumer) }
    mutating func release(_ consumer: String) { consumers.remove(consumer) }
    mutating func clear() { consumers.removeAll() }
}

enum LiveReadDemandSelfTest {
    static func run() throws {
        var demand = LiveReadDemand()
        demand.acquire("menu"); demand.acquire("menu")
        demand.release("menu")
        guard !demand.active else { throw NSError(domain: "LiveReadDemand", code: 1) }
        demand.acquire("menu"); demand.acquire("control")
        demand.release("menu")
        guard demand.active else { throw NSError(domain: "LiveReadDemand", code: 2) }
        demand.release("missing")
        guard demand.active else { throw NSError(domain: "LiveReadDemand", code: 3) }
        demand.release("control")
        guard !demand.active else { throw NSError(domain: "LiveReadDemand", code: 4) }
        demand.acquire("control"); demand.acquire("detached"); demand.clear()
        guard !demand.active else { throw NSError(domain: "LiveReadDemand", code: 5) }
    }
}
