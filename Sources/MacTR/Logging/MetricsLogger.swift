// MetricsLogger.swift — JSONL rolling metrics + event log (§4.4)
//
// Why this exists: during the 8-day chronic E-core stall, `log show` returned
// zero entries, so there was no history to consult. A single time-series line
// ("cores 0,1 at 80% since the 26th") would have ended that investigation
// immediately. Metrics without history can only answer "what is happening now",
// never "is this normal" — which is the question that actually matters.
//
// Hot-path rules (#8160): no subprocesses, append-only writes, all I/O happens on
// the metrics queue. The 0.5s USB render loop is never blocked by logging.

import Darwin
import Foundation

// MARK: - Schema

/// Log schema version. Stamped on EVERY line.
///
/// The retention policy keeps events for 10 years, and a format WILL change over
/// that span. Without a version field, old logs become unreadable and the long
/// retention is pointless. Readers skip unknown versions with a warning rather
/// than aborting, so one bad line never costs the whole file.
let kLogSchemaVersion = 1

enum LogEvent: String, Sendable {
    case watch          // entered suspicion
    case confirm        // promoted to confirmed (chronic)
    case clear          // resolved (hysteresis released)
    case alert          // user notification sent
    case dismiss        // user dismissed an alert
    case resurface      // re-alerted after suppression expired
    case shutdown       // graceful termination marker
    case startup
}

// MARK: - Logger

final class MetricsLogger: @unchecked Sendable {

    static let shared = MetricsLogger()

    /// macOS standard user log location. Deliberately NOT inside the Dropbox
    /// project folder — syncing a file that appends every 30s creates exactly the
    /// sync storm that drives fileproviderd load (see DROPBOX_SYNC_NOTE.md).
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacTR", isDirectory: true)
    }

    private let lock = NSLock()
    private var metricsHandle: FileHandle?
    private var eventHandle: FileHandle?
    private var started = false

    /// Boot-session identity. Log files are split per boot so that "the session we
    /// rebooted out of" stays intact and analyzable (§4.5).
    private(set) lazy var bootTime: Date = MetricsLogger.systemBootTime()
    private(set) lazy var sessionID: String = MetricsLogger.iso(bootTime, fileSafe: true)

    // 30-second aggregation buffer. Writing every 2s sample would be ~15x the
    // volume for no analytic gain; the summary keeps avg AND max AND saturation
    // so downsampling never hides a peak (the §2-B mistake, in the log this time).
    private var bucket: [[Double]] = []
    private var bucketSaturated: [Int: Date] = [:]
    private var bucketStart = Date()
    private var lastMem: MemorySnapshot?
    private var lastTemp: TemperatureSnapshot?
    private var lastLoad: (Double, Double, Double) = (0, 0, 0)
    private var lastSeverity: CPUSeverity = .normal
    private var lastECount: Int = 0

    private static let flushInterval: TimeInterval = 30

    var metricsURL: URL {
        MetricsLogger.logDirectory.appendingPathComponent("boot-\(sessionID).jsonl")
    }
    var eventsURL: URL {
        MetricsLogger.logDirectory.appendingPathComponent("events.jsonl")
    }

    // MARK: Lifecycle

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        do {
            try FileManager.default.createDirectory(at: MetricsLogger.logDirectory,
                                                    withIntermediateDirectories: true)
            metricsHandle = try MetricsLogger.openAppend(metricsURL)
            eventHandle = try MetricsLogger.openAppend(eventsURL)
            logEvent(.startup, kind: "session", id: sessionID,
                     detail: ["boot": MetricsLogger.iso(bootTime)])
            log("[Log] Writing to \(metricsURL.path)")
        } catch {
            log("[Log] Failed to open log files: \(error)")
        }
    }

    /// Graceful-shutdown marker. Its ABSENCE is the signal that a session ended in a
    /// crash or forced reboot — and those are precisely the sessions worth keeping at
    /// full resolution (§4.5 rule 3).
    func markGracefulShutdown() {
        logEvent(.shutdown, kind: "session", id: sessionID, detail: ["graceful": "true"])
        lock.lock()
        try? metricsHandle?.close()
        try? eventHandle?.close()
        metricsHandle = nil
        eventHandle = nil
        lock.unlock()
    }

    // MARK: Metrics stream

    /// Feed one sample. Called from metricsQueue; buffers and flushes every 30s.
    func record(cpu: CPUSnapshot, mem: MemorySnapshot?, temp: TemperatureSnapshot?) {
        lock.lock()
        bucket.append(cpu.perCore)
        for (i, since) in cpu.coreHighLoadSince {
            if bucketSaturated[i] == nil || since < bucketSaturated[i]! { bucketSaturated[i] = since }
        }
        lastMem = mem
        lastTemp = temp
        lastLoad = cpu.loadAvg
        lastSeverity = cpu.severity()
        lastECount = cpu.eCoreCount
        let due = Date().timeIntervalSince(bucketStart) >= MetricsLogger.flushInterval
        let snapshot = due ? bucket : []
        let sat = due ? bucketSaturated : [:]
        if due { bucket.removeAll(keepingCapacity: true); bucketStart = Date() }
        let mem2 = lastMem, temp2 = lastTemp, load = lastLoad, sev = lastSeverity, ec = lastECount
        lock.unlock()

        guard due, !snapshot.isEmpty else { return }
        flush(samples: snapshot, saturated: sat, mem: mem2, temp: temp2,
              load: load, severity: sev, eCount: ec)
    }

    private func flush(samples: [[Double]], saturated: [Int: Date], mem: MemorySnapshot?,
                       temp: TemperatureSnapshot?, load: (Double, Double, Double),
                       severity: CPUSeverity, eCount: Int) {
        let n = samples.first?.count ?? 0
        guard n > 0 else { return }
        var avg = [Double](repeating: 0, count: n)
        var peak = [Double](repeating: 0, count: n)
        for s in samples {
            for i in 0..<min(n, s.count) {
                avg[i] += s[i]
                peak[i] = max(peak[i], s[i])
            }
        }
        for i in 0..<n { avg[i] = (avg[i] / Double(samples.count) * 10).rounded() / 10 }
        for i in 0..<n { peak[i] = (peak[i] * 10).rounded() / 10 }

        var obj: [String: Any] = [
            "v": kLogSchemaVersion,
            "ts": MetricsLogger.iso(Date()),
            "avg": avg,
            // Peak is kept alongside the mean on purpose: a summary that stores only
            // averages reproduces the very illusion this project got caught by (§2-B).
            "max": peak,
            "eIdx": Array(0..<eCount),
            "maxCore": peak.max() ?? 0,
            "sat": peak.filter { $0 >= CPUThresholds.saturated }.count,
            "sev": String(describing: severity),
            "load": [load.0, load.1, load.2],
        ]
        if !saturated.isEmpty {
            obj["satSince"] = saturated.reduce(into: [String: String]()) {
                $0[String($1.key)] = MetricsLogger.iso($1.value)
            }
        }
        if let m = mem {
            obj["memPct"] = (m.percent * 10).rounded() / 10
            obj["pressure"] = m.pressure
            obj["swapUsed"] = m.swapUsed
            obj["swapAct"] = Int(m.swapInPerSec + m.swapOutPerSec)
        }
        if let t = temp, let c = t.cpuTemp { obj["temp"] = (c * 10).rounded() / 10 }

        write(obj, to: .metrics)
    }

    // MARK: Event stream

    /// Events are the primary forensic record — "when did this start, when did it
    /// end, was it dismissed". They are never downsampled (§4.5 rule 2).
    func logEvent(_ event: LogEvent, kind: String, id: String,
                  duration: TimeInterval? = nil, detail: [String: String] = [:]) {
        var obj: [String: Any] = [
            "v": kLogSchemaVersion,
            "ts": MetricsLogger.iso(Date()),
            "event": event.rawValue,
            "kind": kind,
            "id": id,
        ]
        if let d = duration { obj["duration"] = Int(d) }
        if !detail.isEmpty { obj["detail"] = detail }
        write(obj, to: .events)
        log("[Event] \(event.rawValue) \(kind)/\(id)")
    }

    // MARK: Writing

    private enum Stream { case metrics, events }

    private func write(_ obj: [String: Any], to stream: Stream) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let out = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let handle = (stream == .metrics) ? metricsHandle : eventHandle
        do { try handle?.write(contentsOf: out) } catch {
            log("[Log] write failed: \(error)")
        }
    }

    private static func openAppend(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        return h
    }

    // MARK: Helpers

    static func systemBootTime() -> Date {
        var bt = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bt, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(bt.tv_sec))
    }

    static func iso(_ d: Date, fileSafe: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = fileSafe ? "yyyy-MM-dd'T'HH-mm-ss" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.string(from: d)
    }
}
