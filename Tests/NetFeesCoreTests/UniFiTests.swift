import Foundation
import Testing
@testable import NetFeesCore

private let unifiSite = try! UniFiSite(id: "site123", name: "default", displayName: "Home")
private let unifiStart = Date(timeIntervalSince1970: 1_800_000_000)
private let unifiWindow = DateInterval(start: unifiStart, duration: 7200)

@Test func unifiEndpointNormalizesConsoleURLsAndRejectsCredentialLeaks() throws {
    for text in ["https://console.example", "https://console.example/proxy/network/", "https://console.example/proxy/network/integration/v1"] {
        let endpoint = try UniFiEndpoint(text)
        #expect(endpoint.url.absoluteString == "https://console.example/proxy/network")
        #expect(endpoint.url(path: "api/self/sites").absoluteString == "https://console.example/proxy/network/api/self/sites")
        #expect(try JSONDecoder().decode(UniFiEndpoint.self, from: JSONEncoder().encode(endpoint)) == endpoint)
    }
    for text in ["http://console.example", "https://user:password@console.example", "https://console.example?key=example", "https://console.example#key", "https://console.example/../api", "https://console.example:99999"] {
        #expect(throws: (any Error).self) { try UniFiEndpoint(text) }
    }
    #expect(throws: (any Error).self) { try UniFiSite(id: "site", name: "../other", displayName: "Invalid") }
}

@Test func unifiLegacyCountsWANBytesOnceAndExcludesIncompleteIntervals() throws {
    let data = Data(#"{"meta":{"rc":"ok"},"data":[{"time":1800000000000,"wan-rx_bytes":1000000000,"wan-tx_bytes":9000000000,"bytes":9999999999},{"time":1800000000000,"wan-rx_bytes":1000000000,"wan-tx_bytes":9000000000},{"time":1800003600000,"wan-rx_bytes":2000000000,"wan-tx_bytes":10},{"time":1800007200000,"wan-rx_bytes":5000000000,"wan-tx_bytes":90}]}"#.utf8)
    let report = try UniFiParser.report(data, modern: false, site: unifiSite, period: .day, window: unifiWindow)
    #expect(report.buckets.count == 2)
    #expect(report.traffic == Traffic(received: 3_000_000_000, sent: 9_000_000_010))
    #expect(report.fee == Decimal(string: "0.165"))
    #expect(report.coveredSeconds == 7200)
    let restored = try JSONDecoder().decode(UniFiReport.self, from: JSONEncoder().encode(report))
    #expect(restored.traffic == report.traffic)
}

@Test func unifiModernSelectsSiteAndPreservesMissingIntervals() throws {
    let data = Data(#"[{"siteId":"other","series":[{"timestamp":1800000000000,"duration":300000,"rxBytes":999999999,"txBytes":999999999}]},{"siteId":"site123","series":[{"timestamp":1800000000000,"duration":300000,"rxBytes":100.0,"txBytes":20.0},{"timestamp":1800000300000,"duration":300000},{"timestamp":1800000600000,"duration":300000,"rxBytes":0,"txBytes":0}]}]"#.utf8)
    let report = try UniFiParser.report(data, modern: true, site: unifiSite, period: .day, window: unifiWindow)
    #expect(report.traffic == Traffic(received: 100, sent: 20))
    #expect(report.coveredSeconds == 600)
    #expect(report.buckets.count == 2)
}

@Test func unifiNeverTurnsUnavailableOrInvalidDataIntoAZeroBill() throws {
    for json in [
        #"{"meta":{"rc":"error"},"data":[]}"#,
        #"{"meta":{"rc":"ok"},"data":[]}"#,
        #"{"data":[{"time":1800000000000,"bytes":1000000}]}"#,
        #"{"data":[{"time":1800000000000,"wan-rx_bytes":-1,"wan-tx_bytes":2}]}"#,
        #"{"data":[{"time":1800000000000,"wan-rx_bytes":true,"wan-tx_bytes":2}]}"#,
        #"{"data":[{"time":1800000000000,"wan-rx_bytes":10}]}"#,
        #"{"data":[{"time":1800000000000,"wan-rx_bytes":18446744073709551616,"wan-tx_bytes":0}]}"#,
        #"{"data":[{"time":1800000000000,"wan-rx_bytes":10,"wan-tx_bytes":2},{"time":1800000000000,"wan-rx_bytes":20,"wan-tx_bytes":2}]}"#
    ] {
        #expect(throws: (any Error).self) { try UniFiParser.report(Data(json.utf8), modern: false, site: unifiSite, period: .day, window: unifiWindow) }
    }
}

@Test func unifiWindowUsesCompleteHoursAcrossDaylightSaving() {
    let now = ISO8601DateFormatter().date(from: "2026-11-01T08:37:00Z")!
    for period in [UniFiPeriod.day, .week, .month] {
        let window = period.window(at: now)
        #expect(window.duration == Double(period.hours) * 3600)
        #expect(window.end.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0)
        #expect(window.end < now)
    }
}

@Test func unifiTodayUsesLocalMidnightAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = ISO8601DateFormatter().date(from: "2026-11-01T10:37:00Z")!
    let window = UniFiPeriod.today.window(at: now, calendar: calendar)
    #expect(window.start == ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z")!)
    #expect(window.end == now)
    #expect(window.duration == 13_020)
    let data = Data(#"{"data":[{"time":1800000000000,"wan-rx_bytes":100,"wan-tx_bytes":200}]}"#.utf8)
    let current = DateInterval(start: unifiStart, duration: 600)
    let report = try UniFiParser.report(data, modern: false, site: unifiSite, period: .today, window: current)
    #expect(report.traffic.received == 100)
    #expect(report.buckets.first?.end == current.end)
}

@Test func unifiOptionsRejectInvalidIntervalsIncludingDecodedValues() throws {
    for interval in [1, 3, 5, 17, 86_400] {
        let value = try UniFiOptions(showsInMenuBar: true, refreshInterval: interval)
        #expect(try JSONDecoder().decode(UniFiOptions.self, from: JSONEncoder().encode(value)) == value)
    }
    for interval in [-1, 0, 86_401, Int.max] {
        #expect(throws: (any Error).self) { try UniFiOptions(refreshInterval: interval) }
        let data = Data("{\"showsInMenuBar\":true,\"refreshInterval\":\(interval)}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(UniFiOptions.self, from: data) }
    }
    #expect(try UniFiOptions().showsInMenuBar == false)
}

@Test func unifiClientHistoryNormalizesDirectionDeduplicatesAndKeepsOfflineClients() throws {
    let roster = try UniFiParser.stations(Data(#"{"data":[{"mac":"wired","name":"Desktop","is_wired":true},{"mac":"wifi","hostname":"Phone","is_wired":false}]}"#.utf8), online: false)
    let stations = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
    let data = Data(#"{"data":[{"user":"wired","time":1800000000000,"rx_bytes":100,"tx_bytes":10},{"user":"wifi","time":1800000000000,"rx_bytes":3,"tx_bytes":200},{"user":"unknown","time":1800000000000,"rx_bytes":1000,"tx_bytes":1000}]}"#.utf8)
    let report = try UniFiParser.clients([data, data], modern: false, site: unifiSite, stations: stations, period: .day, window: unifiWindow)
    #expect(report.includesLAN)
    #expect(report.clients.map(\.id) == ["wifi", "wired"])
    #expect(report.clients[0].report.traffic == Traffic(received: 200, sent: 3))
    #expect(report.clients[1].report.traffic.received == 100)
    #expect(stations["wired"]?.online == false)
    #expect(report.clients[0].fee == Tariff.fee(downloadBytes: 200))
    let invalid = Data(#"{"data":[{"user":"wired","time":1800000000000,"rx_bytes":-1,"tx_bytes":10}]}"#.utf8)
    #expect(throws: (any Error).self) {
        try UniFiParser.clients([invalid], modern: false, site: unifiSite, stations: stations, period: .day, window: unifiWindow)
    }
}

@Test func unifiLiveRatesUseWANOnceAndStationByteRatesInsteadOfLinkSpeed() throws {
    let rate = try UniFiParser.wanRate(Data(#"{"data":[{"subsystem":"wan","rx_bytes-r":500,"tx_bytes-r":100},{"subsystem":"www","rx_bytes-r":500,"tx_bytes-r":100}]}"#.utf8))
    #expect(rate == Traffic(received: 500, sent: 100))
    let data = Data(#"{"data":[{"mac":"wired","is_wired":true,"wired-tx_bytes-r":123,"wired-rx_bytes-r":45,"rx_rate":1000000},{"mac":"wifi","is_wired":false,"tx_bytes-r":234,"rx_bytes-r":56},{"mac":"missing","rx_rate":1000000}]}"#.utf8)
    let clients = try UniFiParser.stations(data, online: true)
    #expect(clients[0].rate == Traffic(received: 123, sent: 45))
    #expect(clients[1].rate == Traffic(received: 234, sent: 56))
    #expect(clients[2].rate == nil)
    #expect(throws: (any Error).self) { try UniFiParser.wanRate(Data(#"{"data":[]}"#.utf8)) }
}

@Test func unifiModernClientHistoryFiltersSiteAndKeepsWANScope() throws {
    let data = Data(#"[{"siteId":"other","clientId":"other","series":[{"timestamp":1800000000000,"duration":300000,"rxBytes":9999,"txBytes":8888}]},{"siteId":"site123","clientId":"one","series":[{"timestamp":1800000000000,"duration":300000,"rxBytes":100,"txBytes":50},{"timestamp":1800000300000,"duration":300000}]}]"#.utf8)
    let report = try UniFiParser.clients([data], modern: true, site: unifiSite, stations: [:], period: .day, window: unifiWindow)
    #expect(!report.includesLAN)
    #expect(report.clients.count == 1)
    #expect(report.clients[0].report.traffic == Traffic(received: 100, sent: 50))
    #expect(report.clients[0].report.coveredSeconds == 300)
}

@Test func unifiRefusesRedirectsBeforeForwardingTheAPIKey() async throws {
    let endpoint = try UniFiEndpoint("https://console.example")
    let transport = UniFiTransport(endpoint: endpoint)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: endpoint.url)
    let response = HTTPURLResponse(url: endpoint.url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://other.example"])!
    let result = await withCheckedContinuation { continuation in
        transport.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://other.example")!)) { request in
                continuation.resume(returning: request == nil)
            }
    }
    #expect(result)
}
