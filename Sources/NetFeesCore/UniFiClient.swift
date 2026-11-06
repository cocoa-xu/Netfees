import CryptoKit
import Foundation
import Security

public final class UniFiTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: UniFiEndpoint
    private let certificatePin: String?
    private let lock = NSLock()
    private var rejectedFingerprint: String?

    public init(endpoint: UniFiEndpoint, certificatePin: String? = nil) {
        self.endpoint = endpoint
        self.certificatePin = certificatePin
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == endpoint.url.host?.lowercased(),
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        if let certificatePin {
            if fingerprint == certificatePin { completionHandler(.useCredential, URLCredential(trust: trust)); return }
        } else if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        lock.withLock { rejectedFingerprint = fingerprint }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    public func request(path: String, key: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard !key.isEmpty, !key.contains(where: { $0.isNewline }) else { throw UniFiError.key }
        lock.withLock { rejectedFingerprint = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.url(path: path, query: query))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if let fingerprint = lock.withLock({ rejectedFingerprint }) { throw UniFiError.certificate(fingerprint) }
            throw UniFiError.connection
        }
        guard let http = response as? HTTPURLResponse else { throw UniFiError.response }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw UniFiError.redirected
        case 401: throw UniFiError.authentication
        case 403: throw UniFiError.forbidden
        case 404, 405: throw UniFiError.unavailable
        default: throw UniFiError.connection
        }
        guard data.count <= 8_000_000 else { throw UniFiError.response }
        return data
    }
}

public actor UniFiClient {
    private let transport: UniFiTransport
    private let key: String
    private var modernSource: Bool?
    private var knownStations: [String: UniFiStation] = [:]
    private var stationsFetchedAt = Date.distantPast

    public init(endpoint: UniFiEndpoint, key: String, certificatePin: String? = nil) {
        transport = UniFiTransport(endpoint: endpoint, certificatePin: certificatePin)
        self.key = key
    }

    public func sites() async throws -> [UniFiSite] {
        try UniFiParser.sites(await transport.request(path: "api/self/sites", key: key))
    }

    public func report(site: UniFiSite, period: UniFiPeriod, now: Date = Date()) async throws -> UniFiReport {
        let window = period.window(at: now)
        let modern = try await isModern()
        let data: Data
        if modern {
            data = try await series(schema: "wanBySite", site: site, period: period, window: window)
        } else {
            let body = try JSONSerialization.data(withJSONObject: [
                "attrs": ["time", "wan-rx_bytes", "wan-tx_bytes"],
                "start": Int64(window.start.timeIntervalSince1970 * 1000),
                "end": Int64(window.end.timeIntervalSince1970 * 1000)
            ])
            data = try await transport.request(path: "api/s/\(site.name)/stat/report/hourly.site", key: key, body: body)
        }
        do { return try UniFiParser.report(data, modern: modern, site: site, period: period, window: window) }
        catch let error as UniFiError { throw error }
        catch { throw UniFiError.response }
    }

    public func wanRate(site: UniFiSite) async throws -> Traffic {
        try UniFiParser.wanRate(await transport.request(path: "api/s/\(site.name)/stat/health", key: key))
    }

    public func stations(site: UniFiSite, now: Date = Date()) async throws -> [String: UniFiStation] {
        if now.timeIntervalSince(stationsFetchedAt) >= 300 {
            let data = try await transport.request(path: "api/s/\(site.name)/rest/user", key: key)
            let stations = try UniFiParser.stations(data, online: false)
            knownStations = stations.reduce(into: [:]) { $0[$1.id] = $1 }
            stationsFetchedAt = now
        }
        var result = knownStations
        let data = try await transport.request(path: "api/s/\(site.name)/stat/sta", key: key)
        for station in try UniFiParser.stations(data, online: true) { result[station.id] = station }
        return result
    }

    public func clients(site: UniFiSite, period: UniFiPeriod, stations: [String: UniFiStation], now: Date = Date()) async throws -> UniFiClientsReport {
        let window = period.window(at: now)
        let modern = try await isModern()
        let pages: [Data]
        if modern { pages = [try await series(schema: "wanTrafficBySiteByClient", site: site, period: period, window: window)] }
        else {
            var result: [Data] = []
            var start = window.start
            while start < window.end {
                try Task.checkCancellation()
                let end = min(start.addingTimeInterval(86_400), window.end)
                result += try await clientPages(site: site, start: start, end: end)
                start = end
            }
            pages = result
        }
        return try UniFiParser.clients(pages, modern: modern, site: site, stations: stations, period: period, window: window)
    }

    private func clientPages(site: UniFiSite, start: Date, end: Date) async throws -> [Data] {
        let body = try JSONSerialization.data(withJSONObject: ["attrs": ["time", "rx_bytes", "tx_bytes"],
            "start": Int64(start.timeIntervalSince1970 * 1000), "end": Int64(end.timeIntervalSince1970 * 1000)])
        let data = try await transport.request(path: "api/s/\(site.name)/stat/report/hourly.user", key: key, body: body)
        if try UniFiParser.rows(data).count < 3000 { return [data] }
        let middle = Date(timeIntervalSince1970: floor((start.timeIntervalSince1970 + end.timeIntervalSince1970) / 7200) * 3600)
        guard middle > start, middle < end else { throw UniFiError.response }
        let first = try await clientPages(site: site, start: start, end: middle)
        return first + (try await clientPages(site: site, start: middle, end: end))
    }

    private func isModern() async throws -> Bool {
        if let modernSource { return modernSource }
        do {
            let data = try await transport.request(path: "v2/api/stats/source", key: key)
            let source = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
            guard source == "MODERN" || source == "LEGACY" else { throw UniFiError.response }
            modernSource = source == "MODERN"
        } catch UniFiError.unavailable { modernSource = false }
        return modernSource!
    }

    private func series(schema: String, site: UniFiSite, period: UniFiPeriod, window: DateInterval) async throws -> Data {
        try await transport.request(path: "v2/api/stats/recent/series", key: key, query: [
                URLQueryItem(name: "schema", value: schema),
                URLQueryItem(name: "period", value: period.seriesPeriod),
                URLQueryItem(name: "end", value: String(Int64(window.end.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "filter", value: "siteId.eq('\(site.id)')"),
                URLQueryItem(name: "projection", value: "values(rxBytes,txBytes)")
            ])
    }
}
