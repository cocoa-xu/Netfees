import Foundation

public enum UniFiError: Error, LocalizedError, Sendable {
    case endpoint, key, authentication, forbidden, unavailable, response, noTraffic, redirected, certificate(String), connection

    public var errorDescription: String? {
        switch self {
        case .endpoint: "Enter an HTTPS UniFi console URL without a username, password, query, or fragment."
        case .key: "Enter a local UniFi API key."
        case .authentication: "UniFi rejected the API key. Check the key in Settings."
        case .forbidden: "This API key cannot read the site's WAN statistics."
        case .unavailable: "The controller does not provide this statistics API. Use a UniFi OS console with a local API key."
        case .response: "The controller returned an unsupported statistics response."
        case .noTraffic: "No WAN byte statistics are available for this period. A UniFi gateway and retained traffic history are required."
        case .redirected: "The endpoint redirected the request. Enter the console's direct HTTPS URL."
        case .certificate: "The console's HTTPS certificate is not trusted or has changed. Check the connection in Settings."
        case .connection: "Could not reach the UniFi console. Check the address and network connection."
        }
    }
}

public struct UniFiEndpoint: Codable, Equatable, Sendable {
    public let url: URL

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(URL.self, forKey: .url).absoluteString)
    }

    public init(_ text: String) throws {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw UniFiError.endpoint }
        parts.scheme = "https"
        parts.host = host.lowercased()
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/integration/v1", "/integration", "/api"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        if path.isEmpty { path = "proxy/network" }
        parts.path = "/" + path
        guard let url = parts.url else { throw UniFiError.endpoint }
        self.url = url
    }

    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }
}

public struct UniFiSite: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let displayName: String

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      displayName: values.decode(String.self, forKey: .displayName))
    }

    public init(id: String, name: String, displayName: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !id.isEmpty, !name.isEmpty, id.count <= 128, name.count <= 128,
              id.unicodeScalars.allSatisfy(allowed.contains), name.unicodeScalars.allSatisfy(allowed.contains) else { throw UniFiError.response }
        self.id = id
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
    }
}

public enum UniFiPeriod: String, Codable, CaseIterable, Sendable {
    case today, day, week, month
    public var title: String {
        switch self { case .today: "Today"; case .day: "Last 24 hours"; case .week: "Last 7 days"; case .month: "Last 30 days" }
    }
    public var hours: Int { switch self { case .today, .day: 24; case .week: 168; case .month: 720 } }
    public var seriesPeriod: String { switch self { case .today, .day: "DAY"; case .week: "WEEK"; case .month: "MONTH" } }
    public func window(at now: Date, calendar: Calendar = .current) -> DateInterval {
        if self == .today { return DateInterval(start: calendar.startOfDay(for: now), end: now) }
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
        return DateInterval(start: end.addingTimeInterval(-Double(hours) * 3600), end: end)
    }
}

public struct UniFiBucket: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let traffic: Traffic
}

public struct UniFiReport: Codable, Sendable {
    public let fetchedAt: Date
    public let period: UniFiPeriod
    public let window: DateInterval
    public let buckets: [UniFiBucket]
    public let traffic: Traffic
    public var fee: Decimal { Tariff.fee(downloadBytes: traffic.received) }
    public var coveredSeconds: TimeInterval { buckets.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(buckets: values.decode([UniFiBucket].self, forKey: .buckets), period: values.decode(UniFiPeriod.self, forKey: .period),
                      window: values.decode(DateInterval.self, forKey: .window), fetchedAt: values.decode(Date.self, forKey: .fetchedAt))
    }

    public init(buckets: [UniFiBucket], period: UniFiPeriod, window: DateInterval, fetchedAt: Date = Date()) throws {
        var unique: [Date: UniFiBucket] = [:]
        for bucket in buckets where bucket.start >= window.start && bucket.end <= window.end {
            guard bucket.end > bucket.start else { throw UniFiError.response }
            if let previous = unique[bucket.start], previous != bucket { throw UniFiError.response }
            unique[bucket.start] = bucket
        }
        let sorted = unique.values.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { throw UniFiError.noTraffic }
        var total = Traffic()
        var previousEnd = window.start
        for bucket in sorted {
            guard bucket.start >= previousEnd else { throw UniFiError.response }
            let received = total.received.addingReportingOverflow(bucket.traffic.received)
            let sent = total.sent.addingReportingOverflow(bucket.traffic.sent)
            guard !received.overflow, !sent.overflow else { throw UniFiError.response }
            total = Traffic(received: received.partialValue, sent: sent.partialValue)
            previousEnd = bucket.end
        }
        self.buckets = sorted
        self.period = period
        self.window = window
        self.fetchedAt = fetchedAt
        traffic = total
    }
}

public enum UniFiParser {
    public static func sites(_ data: Data) throws -> [UniFiSite] {
        try rows(data).map { row in
            guard let id = row["_id"] as? String, let name = row["name"] as? String else { throw UniFiError.response }
            return try UniFiSite(id: id, name: name, displayName: row["desc"] as? String ?? name)
        }
    }

    public static func report(_ data: Data, modern: Bool, site: UniFiSite, period: UniFiPeriod, window: DateInterval) throws -> UniFiReport {
        var entries = try rows(data)
        if modern {
            let matching = entries.filter { $0["siteId"] as? String == site.id }
            guard matching.count <= 1 else { throw UniFiError.response }
            entries = matching.first?["series"] as? [[String: Any]] ?? []
        }
        var buckets: [UniFiBucket] = []
        for row in entries {
            let rx = modern ? "rxBytes" : "wan-rx_bytes"
            let tx = modern ? "txBytes" : "wan-tx_bytes"
            // Missing counters represent missing observations, never zero usage.
            if row[rx] == nil && row[tx] == nil { continue }
            guard let received = bytes(row[rx]), let sent = bytes(row[tx]),
                  let timestamp = number(row[modern ? "timestamp" : "time"]), timestamp > 0,
                  let duration = modern ? number(row["duration"]) : 3_600_000, duration > 0, duration <= 2_678_400_000 else { throw UniFiError.response }
            let start = Date(timeIntervalSince1970: timestamp / 1000)
            let end = start.addingTimeInterval(duration / 1000)
            buckets.append(UniFiBucket(start: start, end: period == .today ? min(end, window.end) : end, traffic: Traffic(received: received, sent: sent)))
        }
        return try UniFiReport(buckets: buckets, period: period, window: window)
    }

    static func rows(_ data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data)
        if let rows = root as? [[String: Any]] { return rows }
        guard let object = root as? [String: Any] else { throw UniFiError.response }
        if let meta = object["meta"] as? [String: Any], meta["rc"] as? String != "ok" { throw UniFiError.forbidden }
        guard let rows = object["data"] as? [[String: Any]] else { throw UniFiError.response }
        return rows
    }

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func bytes(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, let double = number(value), double >= 0, double < Double(UInt64.max) else { return nil }
        return n.uint64Value
    }
}
