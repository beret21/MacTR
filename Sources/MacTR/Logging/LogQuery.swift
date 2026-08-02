// LogQuery.swift — `--dump-log` reader (§4.4)
//
// No IPC with the running app is needed: the history is a file, so any tool (or
// Claude) can read it without special privileges. This CLI exists only for
// convenience — `--sustained` in particular answers the question the original
// investigation actually needed: "what has been stuck, and for how long".

import Foundation

enum LogQuery {

    static func run(args: [String]) {
        let dir = MetricsLogger.logDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("로그 없음: \(dir.path)")
            return
        }

        let sustained = args.contains("--sustained")
        let lastSpec = value(args, "--last")
        let sessionSpec = value(args, "--session") ?? "current"

        guard let file = pickSession(dir: dir, spec: sessionSpec) else {
            print("세션 파일을 찾지 못했습니다 (--session current|prev|<name>)")
            return
        }
        print("# \(file.lastPathComponent)")

        let cutoff = lastSpec.flatMap(parseDuration).map { Date().addingTimeInterval(-$0) }
        let lines = readLines(file, since: cutoff)

        if sustained {
            printSustained(lines, eventsURL: dir.appendingPathComponent("events.jsonl"))
        } else {
            for l in lines { print(l.raw) }
        }
    }

    // MARK: Session selection

    private static func pickSession(dir: URL, spec: String) -> URL? {
        let sessions = (try? LogRetention.scanSessions(in: dir))?
            .sorted { $0.date > $1.date } ?? []
        switch spec {
        case "current": return sessions.first?.url
        case "prev":    return sessions.count > 1 ? sessions[1].url : nil
        default:
            let direct = dir.appendingPathComponent(spec)
            return FileManager.default.fileExists(atPath: direct.path) ? direct
                 : sessions.first { $0.url.lastPathComponent.contains(spec) }?.url
        }
    }

    // MARK: Reading

    struct Row { let raw: String; let ts: Date; let obj: [String: Any] }

    private static func readLines(_ url: URL, since: Date?) -> [Row] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var rows: [Row] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            // Unknown schema: warn, keep going. Never abort the whole read (§4.5).
            if let v = o["v"] as? Int, v != kLogSchemaVersion {
                FileHandle.standardError.write("warning: unknown schema v\(v), skipped\n".data(using: .utf8)!)
                continue
            }
            guard let tsS = o["ts"] as? String, let ts = LogRetention.parseISO(tsS) else { continue }
            if let since, ts < since { continue }
            rows.append(Row(raw: String(line), ts: ts, obj: o))
        }
        return rows
    }

    // MARK: --sustained

    /// Collapse the series into "core X was saturated from A to B (duration)".
    private static func printSustained(_ rows: [Row], eventsURL: URL) {
        var runs: [String: (start: Date, end: Date, peak: Double)] = [:]
        var closed: [(String, Date, Date, Double)] = []

        for r in rows {
            let maxArr = (r.obj["max"] as? [Double]) ?? (r.obj["avg"] as? [Double]) ?? []
            let eIdx = Set((r.obj["eIdx"] as? [Int]) ?? [])
            let eCount = eIdx.count
            var active = Set<String>()
            for (i, v) in maxArr.enumerated() where v >= CPUThresholds.saturated {
                let label = i < eCount ? "E\(i + 1)" : "P\(i - eCount + 1)"
                active.insert(label)
                if var run = runs[label] {
                    run.end = r.ts; run.peak = max(run.peak, v); runs[label] = run
                } else {
                    runs[label] = (r.ts, r.ts, v)
                }
            }
            for (label, run) in runs where !active.contains(label) {
                closed.append((label, run.start, run.end, run.peak))
                runs.removeValue(forKey: label)
            }
        }
        for (label, run) in runs { closed.append((label, run.start, run.end, run.peak)) }

        if closed.isEmpty {
            print("지속 포화 구간 없음 (임계 \(Int(CPUThresholds.saturated))%)")
        } else {
            print("\n== 지속 포화 구간 ==")
            for (label, s, e, peak) in closed.sorted(by: { $0.2.timeIntervalSince($0.1) > $1.2.timeIntervalSince($1.1) }) {
                let dur = e.timeIntervalSince(s)
                print(String(format: "%-4s  %@ → %@  (%@, 최대 %.0f%%)",
                             (label as NSString).utf8String!,
                             short(s), short(e), Draw.formatDurationLong(dur), peak))
            }
        }

        // Events are the primary forensic record — show them alongside.
        if let text = try? String(contentsOf: eventsURL, encoding: .utf8) {
            let evs = text.split(separator: "\n").suffix(20)
            if !evs.isEmpty {
                print("\n== 최근 이벤트 ==")
                for e in evs {
                    guard let d = e.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else { continue }
                    let dur = (o["duration"] as? Int).map { " (\(Draw.formatDurationLong(TimeInterval($0))))" } ?? ""
                    print("  \(o["ts"] as? String ?? "")  \(o["event"] as? String ?? "")  "
                          + "\(o["kind"] as? String ?? "")/\(o["id"] as? String ?? "")\(dur)")
                }
            }
        }
    }

    // MARK: Helpers

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        let n = Double(s.dropLast()) ?? Double(s)
        guard let n else { return nil }
        switch s.last {
        case "h": return n * 3600
        case "d": return n * 86400
        case "m": return n * 60
        default:  return n
        }
    }

    private static func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}
