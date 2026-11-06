import Foundation

public struct UniFiStation: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let wired: Bool
    public let online: Bool
    public let rate: Traffic?
}

public struct UniFiClientUsage: Codable, Sendable {
    public let id: String
    public let report: UniFiReport
    public var fee: Decimal { report.fee }
}

public struct UniFiClientsReport: Codable, Sendable {
    public let fetchedAt: Date
    public let period: UniFiPeriod
    public let includesLAN: Bool
    public let clients: [UniFiClientUsage]
}

extension UniFiParser {
    public static func stations(_ data: Data, online: Bool) throws -> [UniFiStation] {
        try rows(data).compactMap { row in
            guard let id = row["mac"] as? String, !id.isEmpty else { return nil }
            let wired = row["is_wired"] as? Bool ?? false
            let prefix = wired ? "wired-" : ""
            let rate: Traffic?
            if online, let download = bytes(row["\(prefix)tx_bytes-r"]), let upload = bytes(row["\(prefix)rx_bytes-r"]) {
                // Live counters are reported from the switch or access point's perspective.
                rate = Traffic(received: download, sent: upload)
            } else { rate = nil }
            let name = ["name", "display_name", "hostname"].compactMap { row[$0] as? String }.first { !$0.isEmpty } ?? id
            return UniFiStation(id: id.lowercased(), name: name, wired: wired, online: online, rate: rate)
        }
    }

    public static func wanRate(_ data: Data) throws -> Traffic {
        let matching = try rows(data).filter { $0["subsystem"] as? String == "wan" }
        guard matching.count == 1, let row = matching.first,
              let received = bytes(row["rx_bytes-r"]), let sent = bytes(row["tx_bytes-r"]) else { throw UniFiError.noTraffic }
        return Traffic(received: received, sent: sent)
    }

    public static func clients(_ pages: [Data], modern: Bool, site: UniFiSite, stations: [String: UniFiStation],
                               period: UniFiPeriod, window: DateInterval) throws -> UniFiClientsReport {
        var grouped: [String: [UniFiBucket]] = [:]
        for data in pages {
            let entries = try rows(data)
            if !modern, entries.count >= 3000 { throw UniFiError.response }
            for entry in entries {
                if modern, entry["siteId"] as? String != site.id { continue }
                guard let rawID = entry[modern ? "clientId" : "user"] as? String, !rawID.isEmpty else { throw UniFiError.response }
                let id = rawID.lowercased()
                let samples: [[String: Any]]
                if modern {
                    guard let series = entry["series"] as? [[String: Any]] else { throw UniFiError.response }
                    samples = series
                } else { samples = [entry] }
                for sample in samples {
                    let rx = modern ? "rxBytes" : "rx_bytes"
                    let tx = modern ? "txBytes" : "tx_bytes"
                    if sample[rx] == nil && sample[tx] == nil { continue }
                    guard let received = bytes(sample[rx]), let sent = bytes(sample[tx]),
                          let time = number(sample[modern ? "timestamp" : "time"]), time > 0,
                          let duration = modern ? number(sample["duration"]) : 3_600_000,
                          duration > 0, duration <= 2_678_400_000 else { throw UniFiError.response }
                    let start = Date(timeIntervalSince1970: time / 1000)
                    var end = start.addingTimeInterval(duration / 1000)
                    if period == .today { end = min(end, window.end) }
                    guard start >= window.start, start < window.end, end <= window.end else { continue }
                    // Legacy wireless history uses the AP's direction; wired history is client-oriented.
                    // A known station is required to interpret legacy direction correctly.
                    guard modern || stations[id] != nil else { continue }
                    let swapped = !modern && stations[id]?.wired == false
                    grouped[id, default: []].append(UniFiBucket(start: start, end: end,
                        traffic: Traffic(received: swapped ? sent : received, sent: swapped ? received : sent)))
                }
            }
        }
        var clients: [UniFiClientUsage] = []
        for (id, buckets) in grouped {
            let report = try UniFiReport(buckets: buckets, period: period, window: window)
            clients.append(UniFiClientUsage(id: id, report: report))
        }
        clients.sort {
            let left = $0.report.traffic.received
            let right = $1.report.traffic.received
            return left == right ? $0.id < $1.id : left > right
        }
        return UniFiClientsReport(fetchedAt: Date(), period: period, includesLAN: !modern, clients: clients)
    }
}
