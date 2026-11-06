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
}

@MainActor
final class UniFiModel {
    private(set) var configuration: UniFiConfiguration?
    private(set) var report: UniFiReport?
    private(set) var period = UniFiPeriod.day
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var settingsError: String?
    var onUpdate: (() -> Void)?
    var isEnabled: Bool { configuration?.enabled == true }

    private let settingsURL: URL
    private let cacheURL: URL
    private var client: UniFiClient?
    private var reports: [String: UniFiReport] = [:]
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var isRunning = false

    private struct Cache: Codable {
        let account: String
        let reports: [String: UniFiReport]
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
            report = reports[period.rawValue]
        }
    }

    func start() {
        isRunning = true
        guard isEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 5
        refresh()
    }

    func stop() {
        isRunning = false
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        client = nil
        isRefreshing = false
    }

    func select(_ period: UniFiPeriod) {
        guard self.period != period else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        isRefreshing = false
        self.period = period
        report = reports[period.rawValue]
        error = nil
        refresh()
        onUpdate?()
    }

    func refresh() {
        guard isRunning, isEnabled, let config = configuration, task == nil else { return }
        if client == nil {
            do {
                let key = try UniFiKeychain.read(account: config.keychainAccount, endpoint: config.endpoint, certificatePin: config.certificatePin)
                client = UniFiClient(endpoint: config.endpoint, key: key, certificatePin: config.certificatePin)
            } catch {
                self.error = error.localizedDescription
                onUpdate?()
                return
            }
        }
        guard let client else { return }
        let token = generation
        let requestedPeriod = period
        isRefreshing = true
        onUpdate?()
        task = Task { [weak self] in
            do {
                let report = try await client.report(site: config.site, period: requestedPeriod)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.report = report
                self.reports[requestedPeriod.rawValue] = report
                self.error = nil
                do { try self.saveCache() } catch { self.error = UniFiStorageError.configuration.localizedDescription }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.error = (error as? UniFiError)?.localizedDescription ?? UniFiError.connection.localizedDescription
            }
            guard let self, self.generation == token else { return }
            self.isRefreshing = false
            self.task = nil
            self.onUpdate?()
        }
    }

    func save(endpoint: UniFiEndpoint, site: UniFiSite, key: String, certificatePin: String?, enabled: Bool) throws {
        let account = UUID().uuidString
        try UniFiKeychain.write(key, account: account, endpoint: endpoint, certificatePin: certificatePin)
        let config = UniFiConfiguration(enabled: enabled, endpoint: endpoint, site: site, keychainAccount: account, certificatePin: certificatePin)
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
        if !sameSite { reports = [:]; report = nil }
        try? saveCache()
        if let oldAccount { try? UniFiKeychain.delete(account: oldAccount) }
        if wasRunning { start() }
        onUpdate?()
    }

    func setEnabled(_ enabled: Bool) throws {
        guard var config = configuration else { return }
        config.enabled = enabled
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
        report = nil
        error = nil
        defer { onUpdate?() }
        for url in [settingsURL, cacheURL] where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw UniFiStorageError.configuration }
        }
    }

    private func saveCache() throws {
        guard let config = configuration else { return }
        try JSONEncoder().encode(Cache(account: config.keychainAccount, reports: reports)).write(to: cacheURL, options: .atomic)
    }
}
