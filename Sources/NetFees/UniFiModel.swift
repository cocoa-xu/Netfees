import AppKit
import LocalAuthentication
import NetFeesCore
import Security

enum UniFiKeychain {
    private static let service = "moe.uwucocoa.Netfees.unifi"
    private struct Credential: Codable {
        let key: String
        let endpoint: UniFiEndpoint
        let certificatePin: String?
    }

    static func read(account: String, endpoint: UniFiEndpoint, certificatePin: String?, interactive: Bool = false) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.endpoint == endpoint, credential.certificatePin == certificatePin else {
            throw UniFiStorageError.keychain
        }
        return credential.key
    }

    static func write(_ key: String, account: String, endpoint: UniFiEndpoint, certificatePin: String?) throws {
        let data = try JSONEncoder().encode(Credential(key: key, endpoint: endpoint, certificatePin: certificatePin))
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrLabel as String: "NetFees UniFi API key", kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw UniFiStorageError.keychain }
    }

    static func delete(account: String) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw UniFiStorageError.keychain }
    }
}

enum UniFiStorageError: Error, LocalizedError {
    case keychain, configuration
    var errorDescription: String? {
        switch self {
        case .keychain: "The UniFi API key could not be accessed in Keychain. Unlock the login keychain or enter the key again in Settings."
        case .configuration: "UniFi settings or cached history could not be saved. Check folder permissions and free space."
        }
    }
}

struct UniFiConfiguration: Codable {
    var version = 1
    var enabled: Bool
    let endpoint: UniFiEndpoint
    let site: UniFiSite
    let keychainAccount: String
    let certificatePin: String?
    var options: UniFiOptions

    init(enabled: Bool, endpoint: UniFiEndpoint, site: UniFiSite, keychainAccount: String, certificatePin: String?, options: UniFiOptions) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.site = site
        self.keychainAccount = keychainAccount
        self.certificatePin = certificatePin
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        endpoint = try values.decode(UniFiEndpoint.self, forKey: .endpoint)
        site = try values.decode(UniFiSite.self, forKey: .site)
        keychainAccount = try values.decode(String.self, forKey: .keychainAccount)
        certificatePin = try values.decodeIfPresent(String.self, forKey: .certificatePin)
        options = try values.decodeIfPresent(UniFiOptions.self, forKey: .options) ?? UniFiOptions()
    }
}

@MainActor
final class UniFiModel {
    private(set) var configuration: UniFiConfiguration?
    var report: UniFiReport? { currentReport(for: period) }
    var todayReport: UniFiReport? { currentReport(for: .today) }
    var clientsReport: UniFiClientsReport? {
        guard let value = clientReports[period.rawValue] else { return nil }
        if period == .today, !Calendar.current.isDateInToday(value.fetchedAt) { return nil }
        return value
    }
    private(set) var period = UniFiPeriod.today
    var rate: Traffic? {
        guard let rateUpdatedAt, Date().timeIntervalSince(rateUpdatedAt) <= max(30, Double(refreshInterval) * 3) else { return nil }
        return latestRate
    }
    var hasCurrentStations: Bool {
        guard let stationsUpdatedAt else { return false }
        return clientsError == nil && Date().timeIntervalSince(stationsUpdatedAt) <= max(30, Double(refreshInterval) * 3)
    }
    private(set) var stations: [String: UniFiStation] = [:]
    private(set) var clientsError: String?
    private(set) var todayError: String?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var settingsError: String?
    var onUpdate: (() -> Void)?
    var isEnabled: Bool { configuration?.enabled == true }
    var showsInMenuBar: Bool { isEnabled && configuration?.options.showsInMenuBar == true }
    var refreshInterval: Int { configuration?.options.refreshInterval ?? 5 }

    private let settingsURL: URL
    private let cacheURL: URL
    private var client: UniFiClient?
    private var reports: [String: UniFiReport] = [:]
    private var clientReports: [String: UniFiClientsReport] = [:]
    private var lastCacheWrite = Date.distantPast
    private var retryAfter = Date.distantPast
    private var failures = 0
    private var latestRate: Traffic?
    private var rateUpdatedAt: Date?
    private var stationsUpdatedAt: Date?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var isRunning = false

    private struct Cache: Codable {
        let account: String
        let reports: [String: UniFiReport]
        var clients: [String: UniFiClientsReport]?
        var stations: [String: UniFiStation]?
    }

    init(directory: URL) {
        settingsURL = directory.appendingPathComponent("unifi.json")
        cacheURL = directory.appendingPathComponent("unifi-history.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let config = try JSONDecoder().decode(UniFiConfiguration.self, from: Data(contentsOf: settingsURL))
                guard config.version == 1 else { throw UniFiStorageError.configuration }
                configuration = config
            } catch { settingsError = "UniFi settings could not be read. Reconnect in Settings to replace them." }
        }
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.account == configuration?.keychainAccount {
            reports = cache.reports
            clientReports = cache.clients ?? [:]
            stations = cache.stations ?? [:]
        }
    }

    func start() {
        isRunning = true
        guard isEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = min(1, Double(refreshInterval) / 10)
        refresh()
    }

    func stop() {
        try? saveCache()
        isRunning = false
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        client = nil
        isRefreshing = false
        latestRate = nil
        rateUpdatedAt = nil
        stationsUpdatedAt = nil
    }

    func select(_ period: UniFiPeriod) {
        guard self.period != period else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        isRefreshing = false
        self.period = period
        error = nil
        clientsError = nil
        refresh(force: true)
        onUpdate?()
    }

    private func currentReport(for period: UniFiPeriod) -> UniFiReport? {
        guard let report = reports[period.rawValue] else { return nil }
        if period == .today, report.window.start != Calendar.current.startOfDay(for: Date()) { return nil }
        return report
    }

    var isTodayStale: Bool {
        guard let report = todayReport else { return true }
        return todayError != nil || Date().timeIntervalSince(report.fetchedAt) > max(30, Double(refreshInterval) * 3)
    }

    func refresh(force: Bool = false) {
        guard isRunning, isEnabled, let config = configuration, task == nil,
              force || Date() >= retryAfter else { return }
        if client == nil {
            do {
                let key = try UniFiKeychain.read(account: config.keychainAccount, endpoint: config.endpoint, certificatePin: config.certificatePin)
                client = UniFiClient(endpoint: config.endpoint, key: key, certificatePin: config.certificatePin)
            } catch {
                self.error = error.localizedDescription
                todayError = self.error
                retryAfter = Date().addingTimeInterval(30)
                onUpdate?()
                return
            }
        }
        guard let client else { return }
        let token = generation
        let requestedPeriod = period
        isRefreshing = true
        task = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && self.generation == token }
            do {
                let today = try await client.report(site: config.site, period: .today)
                guard current() else { return }
                self.reports[UniFiPeriod.today.rawValue] = today
                self.todayError = nil
                self.error = nil
                self.failures = 0
                self.retryAfter = .distantPast
                self.onUpdate?()
            } catch {
                guard current() else { return }
                self.todayError = Self.message(error)
                if requestedPeriod == .today { self.error = self.todayError }
                self.failures = min(self.failures + 1, 6)
                self.retryAfter = Date().addingTimeInterval(max(Double(self.refreshInterval), min(60, pow(2, Double(self.failures)))))
            }
            if requestedPeriod != .today,
               force || self.report == nil || Date().timeIntervalSince(self.report!.fetchedAt) >= 60 {
                do {
                    let report = try await client.report(site: config.site, period: requestedPeriod)
                    guard current() else { return }
                    self.reports[requestedPeriod.rawValue] = report
                    self.error = nil
                } catch {
                    guard current() else { return }
                    self.error = Self.message(error)
                }
            }
            let rate = try? await client.wanRate(site: config.site)
            guard current() else { return }
            self.latestRate = rate
            self.rateUpdatedAt = rate == nil ? nil : Date()
            do {
                let stations = try await client.stations(site: config.site)
                guard current() else { return }
                self.stations = stations
                self.stationsUpdatedAt = Date()
                let cached = self.clientsReport
                if force || cached == nil || requestedPeriod == .today || Date().timeIntervalSince(cached!.fetchedAt) >= 60 {
                    let clients = try await client.clients(site: config.site, period: requestedPeriod, stations: stations)
                    guard current() else { return }
                    self.clientReports[requestedPeriod.rawValue] = clients
                }
                self.clientsError = nil
            } catch {
                guard current() else { return }
                self.clientsError = Self.message(error)
            }
            guard current() else { return }
            if Date().timeIntervalSince(self.lastCacheWrite) >= 30 {
                do { try self.saveCache() }
                catch { self.settingsError = UniFiStorageError.configuration.localizedDescription }
            }
            self.isRefreshing = false
            self.task = nil
            self.onUpdate?()
        }
        onUpdate?()
    }

    private static func message(_ error: Error) -> String {
        (error as? UniFiError)?.localizedDescription ?? UniFiError.connection.localizedDescription
    }

    func save(endpoint: UniFiEndpoint, site: UniFiSite, key: String, certificatePin: String?, enabled: Bool, options: UniFiOptions) throws {
        let account = UUID().uuidString
        try UniFiKeychain.write(key, account: account, endpoint: endpoint, certificatePin: certificatePin)
        let config = UniFiConfiguration(enabled: enabled, endpoint: endpoint, site: site, keychainAccount: account, certificatePin: certificatePin, options: options)
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: settingsURL, options: .atomic)
        } catch {
            try? UniFiKeychain.delete(account: account)
            throw UniFiStorageError.configuration
        }
        let oldAccount = configuration?.keychainAccount
        let sameSite = configuration?.endpoint == endpoint && configuration?.site.id == site.id
        let wasRunning = isRunning
        stop()
        configuration = config
        settingsError = nil
        error = nil
        if !sameSite { reports = [:]; clientReports = [:]; stations = [:] }
        try? saveCache()
        if let oldAccount { try? UniFiKeychain.delete(account: oldAccount) }
        if wasRunning { start() }
        onUpdate?()
    }

    func setOptions(_ options: UniFiOptions, enabled: Bool) throws {
        guard var config = configuration else { return }
        config.enabled = enabled
        config.options = options
        do { try JSONEncoder().encode(config).write(to: settingsURL, options: .atomic) }
        catch { throw UniFiStorageError.configuration }
        let wasRunning = isRunning
        stop()
        configuration = config
        if wasRunning { start() }
        onUpdate?()
    }

    func disconnect() throws {
        if let config = configuration { try UniFiKeychain.delete(account: config.keychainAccount) }
        let wasRunning = isRunning
        stop()
        isRunning = wasRunning
        configuration = nil
        reports = [:]
        clientReports = [:]
        stations = [:]
        todayError = nil
        clientsError = nil
        error = nil
        defer { onUpdate?() }
        for url in [settingsURL, cacheURL] where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw UniFiStorageError.configuration }
        }
    }

    private func saveCache() throws {
        guard let config = configuration else { return }
        try JSONEncoder().encode(Cache(account: config.keychainAccount, reports: reports, clients: clientReports, stations: stations)).write(to: cacheURL, options: .atomic)
        lastCacheWrite = Date()
    }
}
