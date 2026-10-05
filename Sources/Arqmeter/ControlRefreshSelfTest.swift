import Foundation

enum ControlRefreshSelfTest {
    static func run() throws {
        var requested: [Int] = []
        var replies: [(HistoricalDashboardSnapshot) -> Void] = []
        let model = ControlCenterModel(readSnapshot: { days, completion in
            requested.append(days); replies.append(completion)
        })
        let fixture = HistoricalDashboardSnapshot(records: [], sessions: [], availability: [], coverage: [],
            olderSourceHistory: [:], recommendations: [], comparability: [:], scanResults: [], error: nil)
        model.refresh(days: 7)
        model.refresh(days: 30)
        model.refresh(days: 1)
        guard requested == [7], model.loading else { throw NSError(domain: "ControlRefresh", code: 1) }
        replies[0](fixture)
        guard requested == [7, 1], model.loading, model.snapshot == nil else {
            throw NSError(domain: "ControlRefresh", code: 2)
        }
        replies[1](fixture)
        guard !model.loading, model.snapshot != nil, requested.count == 2 else {
            throw NSError(domain: "ControlRefresh", code: 3)
        }
        model.refresh(days: 1)
        guard requested == [7, 1, 1], model.loading else { throw NSError(domain: "ControlRefresh", code: 4) }
        replies[2](fixture)
        guard !model.loading else { throw NSError(domain: "ControlRefresh", code: 5) }
    }
}
