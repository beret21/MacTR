// LogRetention.swift — tiered log retention (§4.5)
//
// Policy in one line: keep recent detail, keep old shape, never delete irreversibly.
//
// Runs ONCE at startup (§4.5 rule 5) — the steady-state loop must never walk the
// filesystem (hot-path rule #8160).

import Foundation

enum LogRetention {

    /// Sessions kept at full 30s resolution.
    static let rawSessions = 3
    /// Beyond `rawSessions`, keep 5-minute summaries up to this age…
    static let fiveMinuteWindow: TimeInterval = 90 * 86400
    /// …and 1-hour summaries up to this age. 10y is a deliberate, explicit bound:
    /// "forever" cannot be implemented, it just means "deleted at an undefined time".
    static let maxAge: TimeInterval = 10 * 365 * 86400
    /// Safety net against runaway growth from a bug — the time bound is what
    /// normally governs (projected 10-year total is ~67MB).
    static let sizeCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    struct SessionFile {
        let url: URL
        let date: Date
        let graceful: Bool     // false ⇒ crash/forced reboot ⇒ pinned at full resolution
        let resolution: Res
        enum Res: String { case raw, fiveMin = "5m", hourly = "1h" }
    }

    // MARK: - Entry point

    static func runStartupMaintenance() {
        let dir = MetricsLogger.logDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            var sessions = try scanSessions(in: dir)
            sessions.sort { $0.date > $1.date }   // newest first
            try downsample(sessions)
            try enforceAge(sessions)
            try enforceSizeCap(dir)
        } catch {
            log("[Retention] maintenance failed: \(error)")
        }
    }

    // MARK: - Scan

    static func scanSessions(in dir: URL) throws -> [SessionFile] {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("boot-"), name.hasSuffix(".jsonl") else { return nil }
            let res: SessionFile.Res =
                name.contains(".5m.") ? .fiveMin : (name.contains(".1h.") ? .hourly : .raw)
            let stamp = name
                .replacingOccurrences(of: "boot-", with: "")
                .replacingOccurrences(of: ".jsonl", with: "")
                .replacingOccurrences(of: ".5m", with: "")
                .replacingOccurrences(of: ".1h", with: "")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            let date = f.date(from: stamp)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            return SessionFile(url: url, date: date,
                               graceful: hasGracefulMarker(sessionDate: date),
                               resolution: res)
        }
    }

    /// A session is "graceful" if the event log recorded a shutdown for it.
    ///
    /// Parsed as JSON rather than substring-matched: whitespace differences between
    /// writers would silently make every session look like a crash, which would pin
    /// everything at full resolution and quietly disable downsampling.
    private static func hasGracefulMarker(sessionDate: Date) -> Bool {
        let id = MetricsLogger.iso(sessionDate, fileSafe: true)
        guard let text = try? String(contentsOf: MetricsLogger.logDirectory
            .appendingPathComponent("events.jsonl"), encoding: .utf8) else { return false }
        for line in text.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["event"] as? String) == LogEvent.shutdown.rawValue,
                  (o["id"] as? String) == id
            else { continue }
            return true
        }
        return false
    }

    // MARK: - Downsampling

    private static func downsample(_ sessions: [SessionFile]) throws {
        let now = Date()
        let current = MetricsLogger.shared.sessionID
        for (idx, s) in sessions.enumerated() {
            // Never touch the live session.
            if s.url.lastPathComponent.contains(current) { continue }
            // Recent sessions stay raw.
            if idx < rawSessions { continue }
            // A session that ended without a graceful marker is exactly the one you
            // reboot *because of* — keep every sample (§4.5 rule 3).
            if !s.graceful {
                log("[Retention] pinned (no graceful marker): \(s.url.lastPathComponent)")
                continue
            }
            let age = now.timeIntervalSince(s.date)
            let target: SessionFile.Res = age > fiveMinuteWindow ? .hourly : .fiveMin
            if s.resolution == target || (s.resolution == .hourly && target == .fiveMin) { continue }
            try condense(s, to: target)
        }
    }

    /// Collapse a session file into coarser buckets, preserving avg AND max AND
    /// saturation. Keeping only averages would bake the §2-B illusion into history.
    static func condense(_ s: SessionFile, to res: SessionFile.Res) throws {
        let interval: TimeInterval = (res == .hourly) ? 3600 : 300
        guard let text = try? String(contentsOf: s.url, encoding: .utf8) else { return }

        var out: [String] = []
        var bucketAvg: [Double] = [], bucketMax: [Double] = []
        var bucketCount = 0, satMax = 0
        var bucketStart: Date?
        var lastSev = "normal"

        func emit(_ end: Date) {
            guard bucketCount > 0, let st = bucketStart else { return }
            let avg = bucketAvg.map { ($0 / Double(bucketCount) * 10).rounded() / 10 }
            var obj: [String: Any] = [
                "v": kLogSchemaVersion,
                "ts": MetricsLogger.iso(st),
                "span": Int(end.timeIntervalSince(st)),
                "avg": avg,
                "max": bucketMax.map { ($0 * 10).rounded() / 10 },
                "maxCore": bucketMax.max() ?? 0,
                "sat": satMax,
                "sev": lastSev,
                "res": res.rawValue,
            ]
            obj["downsampled"] = true
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let line = String(data: d, encoding: .utf8) { out.append(line) }
            bucketAvg = []; bucketMax = []; bucketCount = 0; satMax = 0; bucketStart = nil
        }

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            // Unknown schema version: keep the line verbatim rather than dropping it.
            if let v = o["v"] as? Int, v != kLogSchemaVersion {
                out.append(String(line)); continue
            }
            guard let tsStr = o["ts"] as? String, let ts = parseISO(tsStr) else {
                out.append(String(line)); continue
            }
            let avg = (o["avg"] as? [Double]) ?? []
            let mx = (o["max"] as? [Double]) ?? avg
            if bucketStart == nil { bucketStart = ts }
            if let st = bucketStart, ts.timeIntervalSince(st) >= interval { emit(ts); bucketStart = ts }
            if bucketAvg.count < avg.count {
                bucketAvg += [Double](repeating: 0, count: avg.count - bucketAvg.count)
                bucketMax += [Double](repeating: 0, count: avg.count - bucketMax.count)
            }
            for i in 0..<avg.count { bucketAvg[i] += avg[i] }
            for i in 0..<min(mx.count, bucketMax.count) { bucketMax[i] = max(bucketMax[i], mx[i]) }
            satMax = max(satMax, (o["sat"] as? Int) ?? 0)
            lastSev = (o["sev"] as? String) ?? lastSev
            bucketCount += 1
        }
        emit(Date())

        guard !out.isEmpty else { return }
        let newName = s.url.lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: ".\(res.rawValue).jsonl")
        let newURL = s.url.deletingLastPathComponent().appendingPathComponent(newName)
        try out.joined(separator: "\n").appending("\n").write(to: newURL, atomically: true, encoding: .utf8)
        try trash(s.url)
        log("[Retention] condensed \(s.url.lastPathComponent) → \(res.rawValue) (\(out.count) lines)")
    }

    // MARK: - Age / size limits

    private static func enforceAge(_ sessions: [SessionFile]) throws {
        let cutoff = Date().addingTimeInterval(-maxAge)
        for s in sessions where s.date < cutoff {
            try trash(s.url)
            log("[Retention] aged out (>10y): \(s.url.lastPathComponent)")
        }
    }

    private static func enforceSizeCap(_ dir: URL) throws {
        var files = try scanSessions(in: dir)
        func total() -> Int64 {
            files.reduce(0) { acc, f in
                acc + Int64((try? f.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        guard total() > sizeCapBytes else { return }
        log("[Retention] size cap exceeded — reclaiming oldest summaries")
        files.sort { $0.date < $1.date }   // oldest first
        for f in files {
            guard total() > sizeCapBytes else { break }
            guard f.resolution == .hourly else { continue }   // coarsest first
            try trash(f.url)
            files.removeAll { $0.url == f.url }
        }
    }

    // MARK: - Reclaim

    /// Move to Trash — never `removeItem`. Log rotation is automated deletion, and
    /// automated deletion with a logic bug destroys evidence instantly. The Trash is
    /// the undo path. `trashItem` is a first-party API with no subprocess (#8160).
    static func trash(_ url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.date(from: s)
    }
}
