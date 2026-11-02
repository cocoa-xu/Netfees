import Foundation
import Testing
@testable import NetFeesCore

@Test func decimalGigabytesAndDownloadOnly() {
    #expect(Tariff.fee(downloadBytes: 1_000_000_000) == Decimal(string: "0.055"))
    #expect(Tariff.fee(downloadBytes: 576_000_000_000) == Decimal(string: "31.68"))
    #expect(Tariff.fee(downloadBytes: 44_000_000) == Decimal(string: "0.00242"))
    let record = DailyRecord(id: "2026-11-02", downloadBytes: 0, uploadBytes: 1_000_000_000)
    #expect(record.fee == 0)
}

@Test func countersIgnoreBaselineResetAndReconnectedInterfaces() {
    var tracker = CounterTracker()
    #expect(tracker.sample(["en0": .init(index: 1, received: 9_000_000_000, sent: 100)]) == Traffic())
    #expect(tracker.sample(["en0": .init(index: 1, received: 14_000_000_000, sent: 120)]) == Traffic(received: 5_000_000_000, sent: 20))
    #expect(tracker.sample(["en0": .init(index: 1, received: 10, sent: 2)]) == Traffic())
    #expect(tracker.sample(["en0": .init(index: 2, received: 9_000, sent: 900)]) == Traffic())
    #expect(tracker.sample([:]) == Traffic())
    #expect(tracker.sample(["en0": .init(index: 2, received: 20_000, sent: 900)]) == Traffic())
}

private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

@Test func midnightSplitsWithoutLosingBytes() {
    var ledger = Ledger(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    ledger.add(Traffic(received: 101, sent: 33),
               from: instant("2026-11-02T14:59:59Z"), to: instant("2026-11-02T15:00:01Z"))
    #expect(ledger.records["2026-11-02"]?.downloadBytes == 50)
    #expect(ledger.records["2026-11-03"]?.downloadBytes == 51)
    #expect(ledger.records.values.reduce(UInt64(0)) { $0 + $1.uploadBytes } == 33)
}

@Test func daylightSavingAndMultipleDaysPreserveTotals() {
    var ledger = Ledger(timeZone: TimeZone(identifier: "America/New_York")!)
    ledger.add(Traffic(received: 49_000, sent: 49),
               from: instant("2026-10-31T04:00:00Z"), to: instant("2026-11-02T05:00:00Z"))
    #expect(ledger.records["2026-10-31"]?.downloadBytes == 24_000)
    #expect(ledger.records["2026-11-01"]?.downloadBytes == 25_000)
    #expect(ledger.records["2026-11-02"]?.downloadBytes == 0)
    #expect(ledger.records.values.reduce(UInt64(0)) { $0 + $1.uploadBytes } == 49)
}

@Test func backwardsClockDoesNotInventTraffic() {
    var ledger = Ledger(timeZone: .gmt)
    ledger.add(Traffic(received: 10, sent: 10), from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 50))
    #expect(ledger.records.isEmpty)
}

@Test func durableHistoryRoundTripAndCorruption() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LedgerStore(url: folder.appendingPathComponent("ledger.json"))
    var ledger = Ledger(timeZone: .gmt)
    ledger.add(Traffic(received: 1_000_000_000, sent: 50),
               from: instant("2026-11-02T01:00:00Z"), to: instant("2026-11-02T01:00:01Z"))
    try store.save(ledger)
    let loaded = try store.load()
    #expect(loaded.records == ledger.records)
    #expect(loaded.csv.contains("2026-11-02,1000000000,50,0.055,0.055,GMT,1"))
    let corrupt = Data("bad data".utf8)
    try corrupt.write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.url) == corrupt)
}
