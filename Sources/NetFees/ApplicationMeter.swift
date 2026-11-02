import AppKit
import Darwin
import NetFeesCore

struct ApplicationTraffic {
    let identity: ApplicationIdentity
    var traffic: Traffic
}

@MainActor
final class ApplicationMeter {
    var onSample: (([ApplicationTraffic], Date, Date) -> Void)?
    var onFailure: (() -> Void)?
    private var process: Process?
    private var output: FileHandle?
    private var parser = NettopParser()
    private var previousDate: Date?
    private var generation = UUID()
    private var identities = ApplicationIdentityResolver()
    private(set) var lastSnapshotAt = Date.distantPast

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        guard !isRunning else { return }
        parser = NettopParser()
        previousDate = nil
        generation = UUID()
        let generation = generation
        let task = Process()
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? writer.close() }
        var attributes = termios()
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(slave, F_SETFD, FD_CLOEXEC) == 0,
              tcgetattr(slave, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        cfmakeraw(&attributes)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "0", "-s", "2", "-n", "-d", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]
        // A terminal keeps nettop line-buffered instead of delaying several CSV frames.
        task.standardOutput = writer
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        reader.readabilityHandler = { [weak self] handle in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { handle.readabilityHandler = nil; return }
            let data = Data(buffer.prefix(count))
            let date = Date()
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.receive(data, at: date)
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onFailure?()
            }
        }
        do {
            try task.run()
            process = task
            output = reader
            lastSnapshotAt = Date()
        } catch {
            reader.readabilityHandler = nil
            try? reader.close()
            throw error
        }
    }

    func stop() {
        generation = UUID()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil
        try? output?.close()
        process = nil
        output = nil
        previousDate = nil
    }

    private func receive(_ data: Data, at date: Date) {
        for snapshot in parser.append(data, at: date) {
            lastSnapshotAt = date
            defer { previousDate = snapshot.capturedAt }
            // nettop's first delta-mode frame contains pre-existing cumulative bytes.
            guard let previousDate, snapshot.capturedAt > previousDate else { continue }
            var applications: [String: ApplicationTraffic] = [:]
            for process in snapshot.processes {
                let identity = identities.resolve(pid: process.pid, fallbackName: process.name)
                var usage = applications[identity.id] ?? ApplicationTraffic(identity: identity, traffic: Traffic())
                usage.traffic.received += process.traffic.received
                usage.traffic.sent += process.traffic.sent
                applications[identity.id] = usage
            }
            onSample?(Array(applications.values), previousDate, snapshot.capturedAt)
        }
    }
}

@MainActor
private struct ApplicationIdentityResolver {
    private struct CachedIdentity {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let identity: ApplicationIdentity
    }
    private var cache: [Int32: CachedIdentity] = [:]

    mutating func resolve(pid: Int32, fallbackName: String) -> ApplicationIdentity {
        let info = processInfo(pid)
        if let info, let cached = cache[pid], cached.startSeconds == info.pbi_start_tvsec,
           cached.startMicroseconds == info.pbi_start_tvusec { return cached.identity }
        let executable = executableURL(pid)
        var currentPID = pid
        var visited = Set<Int32>()
        var bundleURL: URL?
        while currentPID > 1, visited.count < 20, visited.insert(currentPID).inserted {
            if let url = executableURL(currentPID), let app = enclosingApplication(url) {
                bundleURL = app
                break
            }
            guard let parent = processInfo(currentPID)?.pbi_ppid else { break }
            currentPID = Int32(parent)
        }
        let identity: ApplicationIdentity
        if let bundleURL, let bundle = Bundle(url: bundleURL) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundleURL.deletingPathExtension().lastPathComponent
            identity = ApplicationIdentity(id: bundle.bundleIdentifier.map { "bundle:\($0)" } ?? "app:\(bundleURL.path)",
                                           name: name, bundlePath: bundleURL.path)
        } else {
            identity = ApplicationIdentity(id: executable.map { "process:\($0.path)" } ?? "process:\(fallbackName)",
                                           name: executable?.lastPathComponent ?? fallbackName)
        }
        if let info {
            cache[pid] = CachedIdentity(startSeconds: info.pbi_start_tvsec,
                                       startMicroseconds: info.pbi_start_tvusec, identity: identity)
        }
        if cache.count > 2_000 { cache = cache.filter { kill($0.key, 0) == 0 || errno == EPERM } }
        return identity
    }

    private func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func executableURL(_ pid: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))
    }

    private func enclosingApplication(_ executable: URL) -> URL? {
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in executable.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            if path.pathExtension == "app" { return path }
        }
        return nil
    }
}
