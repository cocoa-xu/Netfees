import AppKit
import NetFeesCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class UsageModel {
    private(set) var ledger: Ledger
    private(set) var now = Date()
    private(set) var rate = Traffic()
    private(set) var interfaces: [String] = []
    private(set) var error: String?
    private(set) var applicationLedger = ApplicationLedger(timeZoneIdentifier: TimeZone.current.identifier)
    private(set) var applicationRates: [String: Traffic] = [:]
    private(set) var applicationStatus = "Connecting to application counters…"
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let store: LedgerStore
    private let applicationStoreURL: URL
    private let applicationMeter = ApplicationMeter()
    private var applicationCanSave = true
    private var applicationStorageError: String?
    private var nextApplicationAttempt = Date.distantPast
    private var lastApplicationSample = Date.distantPast
    private var applicationIcons: [String: NSImage] = [:]
    private var isRunning = false
    private var isSleeping = false
    private var tracker = CounterTracker()
    private var previousDate: Date?
    private var timer: Timer?
    private var lastSave = Date.distantPast
    private var canSave = true
    private var storageError: String?
    var onUpdate: (() -> Void)?

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetFees", isDirectory: true)
        store = LedgerStore(url: root.appendingPathComponent("ledger.json"))
        applicationStoreURL = root.appendingPathComponent("applications.json")
        do {
            ledger = try store.load()
        } catch {
            ledger = Ledger()
            canSave = false
            storageError = "History could not be read. The original file is preserved. This session will not be saved."
        }
        ledger.ensureDay(now)
        error = storageError
        do {
            if FileManager.default.fileExists(atPath: applicationStoreURL.path) {
                applicationLedger = try JSONDecoder().decode(ApplicationLedger.self, from: Data(contentsOf: applicationStoreURL))
                guard applicationLedger.version == 1 else { throw CocoaError(.fileReadUnknown) }
            } else {
                applicationLedger = ApplicationLedger(timeZoneIdentifier: ledger.timeZoneIdentifier)
            }
        } catch {
            applicationLedger = ApplicationLedger(timeZoneIdentifier: ledger.timeZoneIdentifier)
            applicationCanSave = false
            applicationStorageError = "App history could not be read. The original file is preserved."
        }
        applicationMeter.onSample = { [weak self] applications, start, end in
            self?.recordApplications(applications, from: start, to: end)
        }
        applicationMeter.onFailure = { [weak self] in
            self?.applicationRates = [:]
            self?.applicationStatus = "Application counters unavailable. Retrying automatically."
            self?.nextApplicationAttempt = Date().addingTimeInterval(30)
            self?.onUpdate?()
        }
    }

    var today: DailyRecord { ledger.record(on: now) }
    var totalFee: Decimal { ledger.records.values.reduce(0) { $0 + $1.fee } + (ledger.includedInitialImport?.fee ?? 0) }
    var pendingInitialImport: InitialTrafficImport? {
        canSave && ledger.initialImportDecision == .pending ? ledger.initialImport : nil
    }
    var lastWeekDays: [String] {
        (0..<7).reversed().compactMap { offset in
            ledger.calendar.date(byAdding: .day, value: -offset, to: now).map { ledger.dayKey($0) }
        }
    }
    var lastWeek: [DailyRecord] { lastWeekDays.compactMap { ledger.records[$0] } }

    func start() {
        isRunning = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 0.2
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func sample() {
        let date = Date()
        do {
            let counters = try NetworkCounters.read()
            if !counters.isEmpty {
                let total = counters.values.reduce(into: Traffic()) {
                    $0.received += $1.traffic.received
                    $0.sent += $1.traffic.sent
                }
                ledger.prepareInitialImport(total, at: date)
            }
            let delta = tracker.sample(counters)
            let previousDay = ledger.dayKey(now)
            if let previousDate, date > previousDate {
                let seconds = date.timeIntervalSince(previousDate)
                ledger.add(delta, from: previousDate, to: date)
                rate = seconds < 5 ? Traffic(received: UInt64(Double(delta.received) / seconds),
                                             sent: UInt64(Double(delta.sent) / seconds)) : Traffic()
            }
            previousDate = date
            interfaces = counters.keys.sorted()
            now = date
            ledger.ensureDay(date)
            error = storageError
            if date.timeIntervalSince(lastSave) >= 15 || previousDay != ledger.dayKey(date) { save() }
        } catch {
            self.error = "Traffic counters unavailable. Retrying automatically."
            rate = Traffic()
            now = date
        }
        if applicationMeter.isRunning, date.timeIntervalSince(applicationMeter.lastSnapshotAt) > 12 {
            applicationMeter.stop()
            applicationRates = [:]
            applicationStatus = "Application counters unavailable. Retrying automatically."
            nextApplicationAttempt = date.addingTimeInterval(10)
        }
        if isRunning, !isSleeping, !applicationMeter.isRunning, date >= nextApplicationAttempt {
            nextApplicationAttempt = date.addingTimeInterval(30)
            do { try applicationMeter.start() }
            catch { applicationStatus = "Application counters unavailable. Retrying automatically." }
        }
        if date.timeIntervalSince(lastApplicationSample) > 8, !applicationRates.isEmpty { applicationRates = [:] }
        onUpdate?()
    }

    func resolveInitialImport(include: Bool) {
        ledger.resolveInitialImport(include: include)
        save()
        onUpdate?()
    }

    func applications(on day: String) -> [ApplicationUsageRow] {
        applicationLedger.applications.values.compactMap { history in
            guard let record = history.ledger.records[day], record.downloadBytes > 0 || record.uploadBytes > 0 else { return nil }
            return ApplicationUsageRow(identity: history.identity, record: record,
                                       rate: day == today.id ? applicationRates[history.identity.id] ?? Traffic() : Traffic())
        }.sorted {
            if $0.record.downloadBytes != $1.record.downloadBytes { return $0.record.downloadBytes > $1.record.downloadBytes }
            return $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending
        }
    }

    func icon(for identity: ApplicationIdentity) -> NSImage {
        if let cached = applicationIcons[identity.id] { return cached }
        let icon = identity.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
        applicationIcons[identity.id] = icon
        return icon
    }

    private func recordApplications(_ applications: [ApplicationTraffic], from start: Date, to end: Date) {
        let seconds = end.timeIntervalSince(start)
        var rates: [String: Traffic] = [:]
        for application in applications {
            applicationLedger.add(application.traffic, for: application.identity, from: start, to: end)
            if seconds > 0, seconds < 8 {
                rates[application.identity.id] = Traffic(received: UInt64(Double(application.traffic.received) / seconds),
                                                       sent: UInt64(Double(application.traffic.sent) / seconds))
            }
        }
        applicationRates = rates
        lastApplicationSample = end
        applicationStatus = applicationStorageError ?? "Live · highest cost first"
        onUpdate?()
    }

    func save() {
        if canSave {
            do {
                try store.save(ledger)
                storageError = nil
            } catch {
                storageError = "History could not be saved. Check available disk space and folder permissions."
                self.error = storageError
            }
        }
        if applicationCanSave {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try FileManager.default.createDirectory(at: applicationStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(applicationLedger).write(to: applicationStoreURL, options: .atomic)
                applicationStorageError = nil
            } catch {
                applicationStorageError = "App history could not be saved."
                applicationStatus = applicationStorageError!
            }
        }
        lastSave = Date()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        applicationMeter.stop()
        sample()
        save()
    }

    func prepareForSleep() {
        isSleeping = true
        sample()
        applicationMeter.stop()
        applicationRates = [:]
        save()
        onUpdate?()
    }

    func wake() {
        isSleeping = false
        nextApplicationAttempt = .distantPast
        sample()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defer { onUpdate?() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            self.error = "Login item could not be updated: \(error.localizedDescription)"
        }
    }

    func revealHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    func exportCSV() {
        defer { onUpdate?() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "NetFees-\(ledger.dayKey(now)).csv"
        panel.title = "Export network usage and costs"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try ledger.csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "Export failed: \(error.localizedDescription)" }
        }
    }
}

struct ApplicationUsageRow: Identifiable {
    let identity: ApplicationIdentity
    let record: DailyRecord
    let rate: Traffic
    var id: String { identity.id }
}

enum Display {
    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        for (threshold, unit) in [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")] {
            if value >= threshold {
                return String(format: value / threshold >= 100 ? "%.0f %@" : "%.2f %@", value / threshold, unit)
            }
        }
        return "\(bytes) B"
    }

    static func euros(_ amount: Decimal, precise: Bool = false) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return String(format: precise && value < 1 ? "€%.4f" : "€%.2f", value)
    }

    static func applicationEuros(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return String(format: value < 0.01 ? "€%.6f" : value < 1 ? "€%.4f" : "€%.2f", value)
    }
}
