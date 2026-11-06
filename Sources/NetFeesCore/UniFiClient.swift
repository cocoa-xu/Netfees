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

public struct UniFiClient: Sendable {
    private let transport: UniFiTransport
    private let key: String

    public init(endpoint: UniFiEndpoint, key: String, certificatePin: String? = nil) {
        transport = UniFiTransport(endpoint: endpoint, certificatePin: certificatePin)
        self.key = key
    }

    public func sites() async throws -> [UniFiSite] {
        try UniFiParser.sites(await transport.request(path: "api/self/sites", key: key))
    }

    public func report(site: UniFiSite, period: UniFiPeriod, now: Date = Date()) async throws -> UniFiReport {
        let window = period.window(at: now)
        let modern: Bool
        do {
            let data = try await transport.request(path: "v2/api/stats/source", key: key)
            let source = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
            guard source == "MODERN" || source == "LEGACY" else { throw UniFiError.response }
            modern = source == "MODERN"
        } catch UniFiError.unavailable { modern = false }
        let data: Data
        if modern {
            data = try await transport.request(path: "v2/api/stats/recent/series", key: key, query: [
                URLQueryItem(name: "schema", value: "wanBySite"),
                URLQueryItem(name: "period", value: period.seriesPeriod),
                URLQueryItem(name: "end", value: String(Int64(window.end.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "filter", value: "siteId.eq('\(site.id)')"),
                URLQueryItem(name: "projection", value: "values(rxBytes,txBytes)")
            ])
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
}
