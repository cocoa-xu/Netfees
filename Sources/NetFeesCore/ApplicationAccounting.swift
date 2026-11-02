import Foundation

public struct ApplicationIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String?

    public init(id: String, name: String, bundlePath: String? = nil) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
    }
}

public struct ApplicationHistory: Codable, Sendable {
    public var identity: ApplicationIdentity
    public var ledger: Ledger
}

public struct ApplicationLedger: Codable, Sendable {
    public var version = 1
    public let startedAt: Date
    public let timeZoneIdentifier: String
    public private(set) var applications: [String: ApplicationHistory] = [:]

    public init(startedAt: Date = Date(), timeZoneIdentifier: String) {
        self.startedAt = startedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public mutating func add(_ traffic: Traffic, for identity: ApplicationIdentity, from start: Date, to end: Date) {
        guard traffic.received > 0 || traffic.sent > 0, end > start else { return }
        var history = applications[identity.id] ?? ApplicationHistory(identity: identity,
            ledger: Ledger(startedAt: start, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .gmt, offerInitialImport: false))
        history.identity = identity
        history.ledger.add(traffic, from: start, to: end)
        applications[identity.id] = history
    }
}

public struct ProcessTraffic: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let traffic: Traffic
}

public struct ProcessTrafficSnapshot: Sendable {
    public let capturedAt: Date
    public let processes: [ProcessTraffic]
}

public struct NettopParser: Sendable {
    private var pending = Data()
    private var capturedAt: Date?
    private var columns: (received: Int, sent: Int)?
    private var processes: [ProcessTraffic] = []

    public init() {}

    public mutating func append(_ data: Data, at date: Date) -> [ProcessTrafficSnapshot] {
        pending.append(data)
        var result: [ProcessTrafficSnapshot] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            let fields = csvFields(line)
            if fields.first == "", let received = fields.firstIndex(of: "bytes_in"), let sent = fields.firstIndex(of: "bytes_out") {
                if let capturedAt {
                    result.append(ProcessTrafficSnapshot(capturedAt: capturedAt, processes: processes))
                }
                capturedAt = date
                columns = (received, sent)
                processes = []
                continue
            }
            guard let columns, fields.count > max(columns.received, columns.sent),
                  let process = fields.first, let separator = process.lastIndex(of: "."),
                  let pid = Int32(process[process.index(after: separator)...]), pid > 0,
                  let received = UInt64(fields[columns.received]), let sent = UInt64(fields[columns.sent]) else { continue }
            processes.append(ProcessTraffic(pid: pid, name: String(process[..<separator]),
                                            traffic: Traffic(received: received, sent: sent)))
        }
        return result
    }

    private func csvFields(_ line: String) -> [String] {
        var fields = [String]()
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { quoted.toggle() }
            else if character == ",", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field)
        return fields
    }
}
