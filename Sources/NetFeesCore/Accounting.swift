import Foundation

public enum Tariff {
    public static let eurosPerGB = Decimal(string: "0.055")!
    public static func fee(downloadBytes: UInt64) -> Decimal {
        Decimal(downloadBytes) / 1_000_000_000 * eurosPerGB
    }
}

public struct Traffic: Codable, Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received
        self.sent = sent
    }
}

public struct InterfaceCounter: Equatable, Sendable {
    public var index: UInt16
    public var traffic: Traffic

    public init(index: UInt16, received: UInt64, sent: UInt64) {
        self.index = index
        traffic = Traffic(received: received, sent: sent)
    }
}

public struct CounterTracker {
    private var previous: [String: InterfaceCounter] = [:]

    public init() {}

    public mutating func sample(_ counters: [String: InterfaceCounter]) -> Traffic {
        defer { previous = counters }
        var delta = Traffic()
        for (name, current) in counters {
            guard let old = previous[name], old.index == current.index else { continue }
            // A lower counter means a reset, not unsigned wraparound or new traffic.
            if current.traffic.received >= old.traffic.received {
                delta.received += current.traffic.received - old.traffic.received
            }
            if current.traffic.sent >= old.traffic.sent {
                delta.sent += current.traffic.sent - old.traffic.sent
            }
        }
        return delta
    }
}

public struct DailyRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var downloadBytes: UInt64
    public var uploadBytes: UInt64
    public var observedSeconds: TimeInterval

    public var fee: Decimal { Tariff.fee(downloadBytes: downloadBytes) }

    public init(id: String, downloadBytes: UInt64 = 0, uploadBytes: UInt64 = 0,
                observedSeconds: TimeInterval = 0) {
        self.id = id
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.observedSeconds = observedSeconds
    }
}

public struct Ledger: Codable, Sendable {
    public var version = 1
    public var startedAt: Date
    public var timeZoneIdentifier: String
    public private(set) var records: [String: DailyRecord] = [:]

    public init(startedAt: Date = Date(), timeZone: TimeZone = .current) {
        self.startedAt = startedAt
        timeZoneIdentifier = timeZone.identifier
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        return calendar
    }

    public func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public func record(on date: Date) -> DailyRecord {
        records[dayKey(date)] ?? DailyRecord(id: dayKey(date))
    }

    public var sortedRecords: [DailyRecord] {
        records.values.sorted { $0.id > $1.id }
    }

    public mutating func ensureDay(_ date: Date) {
        let key = dayKey(date)
        if records[key] == nil { records[key] = DailyRecord(id: key) }
    }

    public mutating func add(_ traffic: Traffic, from start: Date, to end: Date) {
        guard end > start else { return }
        let duration = end.timeIntervalSince(start)
        var cursor = start
        var remaining = traffic
        while cursor < end {
            guard let interval = calendar.dateInterval(of: .day, for: cursor) else { break }
            let boundary = min(interval.end, end)
            let seconds = boundary.timeIntervalSince(cursor)
            let final = boundary == end
            let received = final ? remaining.received : min(remaining.received, UInt64(Double(traffic.received) * seconds / duration))
            let sent = final ? remaining.sent : min(remaining.sent, UInt64(Double(traffic.sent) * seconds / duration))
            let key = dayKey(cursor)
            var record = records[key] ?? DailyRecord(id: key)
            record.downloadBytes += received
            record.uploadBytes += sent
            record.observedSeconds += seconds
            records[key] = record
            remaining.received -= received
            remaining.sent -= sent
            cursor = boundary
        }
        ensureDay(end)
    }

    public var csv: String {
        let header = "date,download_bytes,upload_bytes,simulated_eur,rate_eur_per_GB,time_zone,observed_seconds"
        let rows = sortedRecords.map {
            "\($0.id),\($0.downloadBytes),\($0.uploadBytes),\(NSDecimalNumber(decimal: $0.fee).stringValue),0.055,\(timeZoneIdentifier),\(Int($0.observedSeconds))"
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

public struct LedgerStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        guard ledger.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return ledger
    }

    public func save(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }
}
