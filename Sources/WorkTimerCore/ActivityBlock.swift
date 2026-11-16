import Foundation

/// Category counters, not a reconstruction of switch order inside a five-minute window.
public struct ActivityBlock: Codable, Equatable, Identifiable {
    public static let length = 5 * Duration.minute
    public var start: Millis
    public var amounts: [Category: Millis]
    public var coverage: [Span]
    public var apps: [String]
    public var id: Millis { start }
    public var span: Span { Span(start, start + Self.length) }
    public var observed: Millis { amounts.values.reduce(0, +) }
    public subscript(_ category: Category) -> Millis { amounts[category, default: 0] }

    public init(start: Millis, amounts: [Category: Millis] = [:], coverage: [Span] = [], apps: [String] = []) {
        self.start = start; self.amounts = amounts; self.coverage = coverage
        self.apps = Array(Set(apps)).sorted()
    }

    private enum CodingKeys: String, CodingKey { case start, amounts, coverage, apps }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Millis.self, forKey: .start)
        amounts = try values.decode([Category: Millis].self, forKey: .amounts)
        coverage = try values.decode([Span].self, forKey: .coverage)
        apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
    }

    public static func floor(_ time: Millis) -> Millis {
        let remainder = time % length
        return time - remainder - (remainder < 0 ? length : 0)
    }

    public static func selectionRange(orderedIDs: [Millis], anchor: Millis?, target: Millis) -> Set<Millis> {
        guard let end = orderedIDs.firstIndex(of: target) else { return [] }
        let start = anchor.flatMap { orderedIDs.firstIndex(of: $0) } ?? end
        return Set(orderedIDs[min(start, end)...max(start, end)])
    }

    public mutating func add(_ range: Span, category: Category, apps: [String] = []) throws {
        guard let cut = span.intersection(range) else { return }
        guard !coverage.contains(where: { $0.overlaps(cut) }) else { throw LedgerError.overlap(cut) }
        amounts[category, default: 0] += cut.length
        coverage = Self.union(coverage + [cut])
        self.apps = Array(Set(self.apps + apps)).sorted()
    }

    public static func union(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= span.start {
                result[result.count - 1].end = max(last.end, span.end)
            } else { result.append(span) }
        }
        return result
    }

    public mutating func apply(_ adjustment: Adjustment, reviewSource: Category? = nil, reviewAmount: Millis? = nil) throws {
        guard span.overlaps(adjustment.span) else { return }
        if adjustment.kind == .manual {
            guard let cut = span.intersection(adjustment.span) else { return }
            if cut == span {
                // A manual entry replaces everything recorded in the block, including its apps.
                amounts = [adjustment.category: Self.length]
                coverage = [span]
                apps = []
                return
            }
            let existing = coverage.compactMap { $0.intersection(cut) }.reduce(0) { $0 + $1.length }
            amounts[adjustment.category, default: 0] += cut.length - existing
            coverage = Self.union(coverage + [cut])
        } else if adjustment.reviewID != nil {
            let source = reviewSource ?? .gap
            let reviewed = min(self[source], reviewAmount ?? self[source])
            amounts[source, default: 0] -= reviewed
            amounts[adjustment.category, default: 0] += reviewed
        } else {
            let total = observed
            amounts = [adjustment.category: total]
        }
    }

    public func validate() throws {
        guard start == Self.floor(start), amounts.values.allSatisfy({ $0 >= 0 }),
              observed <= Self.length, coverage == Self.union(coverage),
              coverage.allSatisfy({ $0.start >= span.start && $0.end <= span.end }),
              coverage.reduce(0, { $0 + $1.length }) == observed,
              apps == Array(Set(apps)).sorted(), apps.allSatisfy({ !$0.isEmpty }) else {
            throw SQLiteError.invalid("Invalid five-minute block at \(start)")
        }
    }
}

public enum BlockAccounting {
    /// A reporting projection; retain source counters so later observations can change the winner.
    public static func accounted(_ block: ActivityBlock, schedule: Schedule) -> ActivityBlock? {
        guard block.observed > 0 else { return nil }
        var amounts = block.amounts
        amounts[.away, default: 0] += amounts.removeValue(forKey: .idle) ?? 0
        // The order also defines deterministic ties, with Work taking precedence.
        let priority: [Category] = [.work, .learn, .privateTime, .breakTime, .away, .gap]
        let winner: Category
        if schedule.workingSpans(in: block.span).isEmpty, block[.work] > 0 {
            winner = .work
        } else {
            winner = priority.reduce(priority[0]) { best, category in
                amounts[category, default: 0] > amounts[best, default: 0] ? category : best
            }
        }
        return ActivityBlock(start: block.start, amounts: [winner: ActivityBlock.length], coverage: [block.span], apps: block.apps)
    }

    public static func aggregate(_ intervals: [ActivityInterval]) throws -> [ActivityBlock] {
        var blocks: [Millis: ActivityBlock] = [:]
        for interval in intervals {
            var start = interval.span.start
            let category: Category = interval.category == .idle ? .away : interval.category
            while start < interval.span.end {
                let key = ActivityBlock.floor(start)
                let end = min(interval.span.end, key + ActivityBlock.length)
                var block = blocks[key] ?? ActivityBlock(start: key)
                try block.add(Span(start, end), category: category, apps: interval.apps)
                blocks[key] = block
                start = end
            }
        }

        return blocks.values.sorted { $0.start < $1.start }
    }
}

/// A display group retaining the original blocks for individual corrections.
public struct ActivityBlockGroup: Equatable, Identifiable {
    public private(set) var blocks: [ActivityBlock]
    public var id: Millis { blocks[0].start }
    public var span: Span { Span(blocks[0].span.start, blocks[blocks.count - 1].span.end) }
    public var observed: Millis { blocks.reduce(0) { $0 + $1.observed } }

    private init(_ block: ActivityBlock) { blocks = [block] }

    public static func groupingAway(_ blocks: [ActivityBlock], completedThrough: Millis) -> [ActivityBlockGroup] {
        var groups: [ActivityBlockGroup] = []
        var previousWasAway = false
        for original in blocks.sorted(by: { $0.start < $1.start }) {
            var block = original
            if let idle = block.amounts.removeValue(forKey: .idle) {
                block.amounts[.away, default: 0] += idle
            }
            let canGroup = block.observed == ActivityBlock.length
                && block[.away] == block.observed
                && block.coverage == [block.span]
                && block.span.end <= completedThrough
            if canGroup, previousWasAway, let last = groups.last, last.span.end == block.span.start {
                groups[groups.count - 1].blocks.append(block)
            } else {
                groups.append(ActivityBlockGroup(block))
            }
            previousWasAway = canGroup
        }
        return groups
    }
}
