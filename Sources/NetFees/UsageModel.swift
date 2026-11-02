import AppKit
import Combine
import NetFeesCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var ledger: Ledger
    @Published private(set) var now = Date()
    @Published private(set) var rate = Traffic()
    @Published private(set) var interfaces: [String] = []
    @Published private(set) var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let store: LedgerStore
    private var tracker = CounterTracker()
    private var previousDate: Date?
    private var timer: Timer?
    private var lastSave = Date.distantPast
    private var canSave = true
    private var storageError: String?
    var onUpdate: (() -> Void)?

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = LedgerStore(url: root.appendingPathComponent("NetFees/ledger.json"))
        do {
            ledger = try store.load()
        } catch {
            ledger = Ledger()
            canSave = false
            storageError = "History could not be read. The original file is preserved. This session will not be saved."
        }
        ledger.ensureDay(now)
        error = storageError
    }

    var today: DailyRecord { ledger.record(on: now) }
    var totalFee: Decimal { ledger.records.values.reduce(0) { $0 + $1.fee } }
    var lastWeek: [DailyRecord] {
        (0..<7).reversed().compactMap { offset in
            ledger.calendar.date(byAdding: .day, value: -offset, to: now).map { ledger.record(on: $0) }
        }
    }

    func start() {
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
        onUpdate?()
    }

    func save() {
        guard canSave else { return }
        do {
            try store.save(ledger)
            lastSave = Date()
            storageError = nil
        } catch {
            storageError = "History could not be saved. Check available disk space and folder permissions."
            self.error = storageError
        }
    }

    func stop() {
        timer?.invalidate()
        sample()
        save()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "NetFees-\(ledger.dayKey(now)).csv"
        panel.title = "Export your imaginary bill"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try ledger.csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "Export failed: \(error.localizedDescription)" }
        }
    }
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
}
