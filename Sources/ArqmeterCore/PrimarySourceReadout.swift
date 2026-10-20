import Foundation

/// A display selection, not a new collector. It never substitutes another
/// harness when the selected source has no usable metric in this period.
public struct PrimarySourceReadout: Sendable {
    public let harnessID: String
    public let installed: Bool
    public let readable: Bool
    public let aggregate: UsageAggregate
    public let lastEventAt: Date?
    public let lastProvenance: String?
    public let lastModelID: String?
    public let periodStart: Date
    public let periodEnd: Date

    public init?(usage: UnifiedUsage, primaryID: String, from start: Date, to end: Date) {
        guard let source = usage.sources.first(where: { $0.harnessID == primaryID }) else { return nil }
        harnessID = source.harnessID
        periodStart = start
        periodEnd = end
        installed = source.installed
        readable = source.readable
        aggregate = UsageAggregate(records: source.records.filter {
            $0.harnessID == primaryID && $0.timestamp > start && $0.timestamp <= end
        })
        let last = aggregate.records.last
        lastEventAt = last?.timestamp
        lastProvenance = last?.provenance
        lastModelID = last?.modelID
    }

    /// A total is shown only when both components cover every event. A local
    /// duration-only log (for example Ollama) can never become a token zero.
    public var completeTotalTokens: Int64? {
        guard aggregate.inputTokens.complete, aggregate.outputTokens.complete,
              let input = aggregate.inputTokens.value, let output = aggregate.outputTokens.value else { return nil }
        let (total, overflow) = input.addingReportingOverflow(output)
        return overflow ? nil : total
    }

    /// Derived average over a rolling interval of observed, complete token
    /// events. It is not an instantaneous model decoding rate.
    public var observedTokensPerSecond: Double? {
        guard let total = completeTotalTokens else { return nil }
        let seconds = periodEnd.timeIntervalSince(periodStart)
        return seconds > 0 ? Double(total) / seconds : nil
    }

    /// Gaps are nil, not zero: an index with no event is not proof that no
    /// provider activity occurred. An incomplete event also leaves its bin nil.
    public func tokenBuckets(count: Int) -> [Int64?] {
        guard count > 0, periodEnd > periodStart else { return [] }
        var values = Array<Int64?>(repeating: nil, count: count)
        var incomplete = Array(repeating: false, count: count)
        let step = periodEnd.timeIntervalSince(periodStart) / Double(count)
        for record in aggregate.records {
            let index = min(count - 1, max(0, Int(ceil(record.timestamp.timeIntervalSince(periodStart) / step)) - 1))
            guard case .measured(let input) = record.inputTokens,
                  case .measured(let output) = record.outputTokens else {
                incomplete[index] = true
                continue
            }
            let (total, overflow) = input.addingReportingOverflow(output)
            guard !overflow else { incomplete[index] = true; continue }
            let (sum, sumOverflow) = (values[index] ?? 0).addingReportingOverflow(total)
            if sumOverflow { incomplete[index] = true } else { values[index] = sum }
        }
        return values.enumerated().map { incomplete[$0.offset] ? nil : $0.element }
    }
}
