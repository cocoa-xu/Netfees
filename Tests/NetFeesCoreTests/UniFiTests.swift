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
    for period in UniFiPeriod.allCases {
        let window = period.window(at: now)
        #expect(window.duration == Double(period.hours) * 3600)
        #expect(window.end.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0)
        #expect(window.end < now)
    }
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
