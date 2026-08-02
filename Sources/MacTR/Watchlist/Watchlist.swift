// Watchlist.swift — persistent suspicion tracking (§4.6)
//
// The failure this addresses was not measurement. Every sample was correct; nobody
// remembered that the same two cores were also saturated yesterday. Watching means
// carrying state across samples so "this has been true for 8 days" can be said.
//
// DETECTION AND PROMOTION ARE PURE RULES — no inference model. The original misread
// came from a constant error (inverted core mapping), not from lack of intelligence;
// a reasoning layer on top would have narrated the wrong label fluently. Learned
// baselines are worse still: 8 days of saturation is exactly what a baseline absorbs
// as "this machine's normal" (#8148). Rules also leave an auditable reason.

import Darwin
import Foundation

// MARK: - Model

enum WatchKind: String, Sendable {
    case core
    case process
    case diag       // macOS' own cpu_resource.diag filings
}

enum WatchState: String, Sendable {
    case watching     // threshold crossed; not yet chronic
    case confirmed    // sustained past the chronic threshold
}

struct WatchItem: Sendable {
    let kind: WatchKind
    let id: String            // "E1", "fileproviderd", "biomesyncd"
    var state: WatchState
    let since: Date           // first crossing
    var confirmedAt: Date?
    var lastValue: Double
    var detail: String

    func duration(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(since) }
}

// MARK: - Watchlist

final class Watchlist: @unchecked Sendable {

    static let shared = Watchlist()

    /// Suspicion is registered immediately, but promotion to `confirmed` waits out
    /// this window after boot so that indexing/migration bursts don't cry wolf.
    /// Registration is NOT delayed — this very incident began at boot, and a grace
    /// period on detection would have hidden it (§4.6).
    /// Overridable via `MACTR_BOOT_GRACE` for verification (§5.6).
    static let bootGrace: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["MACTR_BOOT_GRACE"],
           let v = TimeInterval(s) { return v }
        return 15 * 60
    }()
    /// Sustained past this ⇒ chronic, not a spike.
    static let chronicAfter: TimeInterval = CPUThresholds.chronic

    private let lock = NSLock()
    private var items: [String: WatchItem] = [:]        // key = "kind/id"
    private var seenDiagFiles: Set<String> = []
    private var diagPrimed = false

    private let logger = MetricsLogger.shared

    var all: [WatchItem] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.values)
    }

    var confirmed: [WatchItem] {
        all.filter { $0.state == .confirmed }
    }

    private func key(_ k: WatchKind, _ id: String) -> String { "\(k.rawValue)/\(id)" }

    // MARK: Core observation

    /// Feed the current CPU snapshot. Core saturation timing comes from the collector,
    /// which already applies 80%-enter / 70%-release hysteresis so an item does not
    /// flap on and off while a core hovers at the boundary.
    func observe(cpu: CPUSnapshot, now: Date = Date()) {
        for i in 0..<cpu.perCore.count {
            // Same labels the display uses, sourced from the device tree so an alert
            // can never name a different core than the screen shows.
            let label = CoreTopology.label(forIndex: i)
            if let since = cpu.coreHighLoadSince[i] {
                upsert(kind: .core, id: label, value: cpu.perCore[i], since: since,
                       detail: String(format: "%.0f%%", cpu.perCore[i]), now: now)
            } else {
                clear(kind: .core, id: label, now: now)
            }
        }
    }

    // MARK: macOS' own filings — highest-value signal, lowest cost

    /// `/Library/Logs/DiagnosticReports/*.cpu_resource.diag` is macOS reporting a
    /// CPU-limit breach itself. No thresholds to tune, no inference, no polling of
    /// live state — the evidence is already on disk, with the process name and
    /// timestamp in the filename. In the original investigation this produced
    /// `biomesyncd 17` and `spotlightknowledged 12` immediately (§3.4).
    func scanDiagnosticReports(now: Date = Date()) {
        let dirs = ["/Library/Logs/DiagnosticReports",
                    NSHomeDirectory() + "/Library/Logs/DiagnosticReports"]
        var counts: [String: Int] = [:]
        var fresh: [String] = []

        for dir in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".cpu_resource.diag") {
                // Filename format: <process>_<timestamp>_<host>.cpu_resource.diag
                let proc = String(name.split(separator: "_").first ?? "unknown")
                counts[proc, default: 0] += 1
                let full = dir + "/" + name
                if !seenDiagFiles.contains(full) {
                    seenDiagFiles.insert(full)
                    if diagPrimed { fresh.append(proc) }
                }
            }
        }

        // First scan establishes the baseline AND surfaces what already exists —
        // pre-existing filings are confirmed evidence, not noise to be ignored.
        for (proc, n) in counts where n > 0 {
            upsert(kind: .diag, id: proc, value: Double(n), since: now,
                   detail: "\(n)건 신고", now: now,
                   // Already-adjudicated by macOS: no grace period, straight to confirmed.
                   forceConfirm: true)
        }
        if !diagPrimed { diagPrimed = true }
        for p in fresh { log("[Watchlist] new cpu_resource filing: \(p)") }
    }

    // MARK: State machine

    private func upsert(kind: WatchKind, id: String, value: Double, since: Date,
                        detail: String, now: Date, forceConfirm: Bool = false) {
        let k = key(kind, id)
        lock.lock()
        var item = items[k]
        let isNew = item == nil
        if isNew {
            item = WatchItem(kind: kind, id: id, state: .watching, since: since,
                             confirmedAt: nil, lastValue: value, detail: detail)
        } else {
            item!.lastValue = value
            item!.detail = detail
        }

        // Promotion requires sustained duration AND that we're past the boot grace
        // window (benign startup bursts). Filings by macOS skip both.
        let uptime = now.timeIntervalSince(MetricsLogger.shared.bootTime)
        let sustained = now.timeIntervalSince(item!.since) >= Watchlist.chronicAfter
        let pastGrace = uptime >= Watchlist.bootGrace
        var promoted = false
        if item!.state == .watching, forceConfirm || (sustained && pastGrace) {
            item!.state = .confirmed
            item!.confirmedAt = now
            promoted = true
        }
        items[k] = item!
        let snapshot = item!
        lock.unlock()

        if isNew {
            logger.logEvent(.watch, kind: kind.rawValue, id: id, detail: ["value": detail])
        }
        if promoted {
            logger.logEvent(.confirm, kind: kind.rawValue, id: id,
                            duration: snapshot.duration(now: now), detail: ["value": detail])
            AlertManager.shared.onConfirmed(snapshot)
        }
    }

    private func clear(kind: WatchKind, id: String, now: Date) {
        let k = key(kind, id)
        lock.lock()
        guard let item = items.removeValue(forKey: k) else { lock.unlock(); return }
        lock.unlock()
        logger.logEvent(.clear, kind: kind.rawValue, id: id, duration: item.duration(now: now))
        AlertManager.shared.onCleared(item)
    }

    // MARK: Process observation (proc_pidinfo — no `ps` shell-out, #8160)

    private var prevProcCPU: [pid_t: (ticks: UInt64, at: Date)] = [:]

    /// Top CPU consumers by *delta* of accumulated CPU time. A single instantaneous
    /// sample lands in a lull and reads 0% for a bursty process — the exact trap that
    /// made `fileproviderd` look idle during the original investigation (§3.2).
    func observeProcesses(now: Date = Date(), threshold: Double = 50) {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var current: [pid_t: (ticks: UInt64, at: Date)] = [:]
        for i in 0..<count where pids[i] > 0 {
            let pid = pids[i]
            var info = proc_taskinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                  Int32(MemoryLayout<proc_taskinfo>.size))
            guard sz == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            let ticks = info.pti_total_user + info.pti_total_system   // nanoseconds
            current[pid] = (ticks, now)

            guard let prev = prevProcCPU[pid] else { continue }
            let elapsed = now.timeIntervalSince(prev.at)
            guard elapsed > 0.5, ticks >= prev.ticks else { continue }
            let cpuPct = Double(ticks - prev.ticks) / 1e9 / elapsed * 100

            if cpuPct >= threshold {
                let name = processName(pid)
                upsert(kind: .process, id: name, value: cpuPct, since: now,
                       detail: String(format: "%.0f%%", cpuPct), now: now)
            }
        }
        prevProcCPU = current
    }

    private func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let n = String(cString: buf)
        return n.isEmpty ? "pid\(pid)" : n
    }
}
