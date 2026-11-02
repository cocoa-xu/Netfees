import Foundation
import Testing
@testable import NetFeesCore

@Test func initialImportIsSeparateDurableAndOnlyCountedOnce() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var ledger = Ledger(startedAt: date, timeZone: .gmt)
    ledger.prepareInitialImport(Traffic(received: 5_000_000_000, sent: 20), at: date)
    ledger.add(Traffic(received: 1_000, sent: 10), from: date, to: date.addingTimeInterval(1))
    #expect(ledger.includedInitialImport == nil)
    var restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
    restored.prepareInitialImport(Traffic(received: 8_000_000_000, sent: 30), at: date.addingTimeInterval(2))
    restored.resolveInitialImport(include: true)
    #expect(restored.includedInitialImport?.traffic.received == 5_000_000_000)
    #expect(restored.includedInitialImport?.fee == Decimal(string: "0.275"))
    #expect(restored.record(on: date).downloadBytes == 1_000)
    #expect(restored.csv.contains("unknown,5000000000,20,0.275"))
    restored.resolveInitialImport(include: false)
    #expect(restored.initialImportDecision == .included)
}

@Test func decliningImportDoesNotBillExistingCounters() {
    var ledger = Ledger(timeZone: .gmt)
    ledger.prepareInitialImport(Traffic(received: 1_000_000_000), at: Date())
    ledger.resolveInitialImport(include: false)
    #expect(ledger.initialImportDecision == .declined)
    #expect(ledger.includedInitialImport == nil)
    #expect(!ledger.csv.contains("initial_import,"))
}

@Test func oldHistoryNeverOffersToImportAlreadyRecordedTraffic() throws {
    let oldJSON = Data(#"{"version":1,"startedAt":0,"timeZoneIdentifier":"GMT","records":{"2026-11-02":{"id":"2026-11-02","downloadBytes":1234,"uploadBytes":56,"observedSeconds":2}}}"#.utf8)
    var ledger = try JSONDecoder().decode(Ledger.self, from: oldJSON)
    ledger.prepareInitialImport(Traffic(received: 9_000_000_000), at: Date())
    #expect(ledger.initialImportDecision == nil)
    #expect(ledger.initialImport == nil)
    #expect(ledger.records["2026-11-02"]?.downloadBytes == 1234)
}

@Test func applicationHistoryMergesHelpersAndSplitsMidnight() throws {
    let start = ISO8601DateFormatter().date(from: "2026-11-02T23:59:59Z")!
    var ledger = ApplicationLedger(startedAt: start, timeZoneIdentifier: "GMT")
    let browser = ApplicationIdentity(id: "bundle:test.browser", name: "Browser")
    ledger.add(Traffic(received: 101, sent: 9), for: browser, from: start, to: start.addingTimeInterval(2))
    ledger.add(Traffic(received: 21, sent: 1), for: browser, from: start, to: start.addingTimeInterval(2))
    #expect(ledger.applications.count == 1)
    #expect(ledger.applications[browser.id]?.ledger.records["2026-11-02"]?.downloadBytes == 60)
    #expect(ledger.applications[browser.id]?.ledger.records["2026-11-03"]?.downloadBytes == 62)
    let restored = try JSONDecoder().decode(ApplicationLedger.self, from: JSONEncoder().encode(ledger))
    #expect(restored.applications[browser.id]?.ledger.records == ledger.applications[browser.id]?.ledger.records)
    #expect(restored.applications[browser.id]?.ledger.initialImportDecision == nil)
}

@Test func nettopParserHandlesChunkedFramesNamesAndColumnOrder() {
    var parser = NettopParser()
    let date = Date(timeIntervalSince1970: 100)
    #expect(parser.append(Data(",bytes_out,bytes_in,\nBrowser.Helper.42,2,5000000000,\n\"App, Name.7\",4,".utf8), at: date).isEmpty)
    #expect(parser.append(Data("8,\ninvalid.8,-1,4,\n".utf8), at: date).isEmpty)
    let first = parser.append(Data(",bytes_out,bytes_in,\nBrowser.Helper.42,3,20,\n".utf8), at: date.addingTimeInterval(2))
    #expect(first.count == 1)
    #expect(first[0].capturedAt == date)
    #expect(first[0].processes.count == 2)
    #expect(first[0].processes[0].pid == 42)
    #expect(first[0].processes[0].name == "Browser.Helper")
    #expect(first[0].processes[0].traffic.received == 5_000_000_000)
    #expect(first[0].processes[1].name == "App, Name")
    let second = parser.append(Data(",bytes_out,bytes_in,\n".utf8), at: date.addingTimeInterval(4))
    #expect(second[0].processes[0].traffic == Traffic(received: 20, sent: 3))
}
