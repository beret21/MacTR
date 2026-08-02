// AlertManager.swift — user notifications for confirmed watchlist items (§4.7)
//
// Logs answer questions after the fact; alerts are what prevent the incident. During
// the 8-day stall the data was on screen the whole time — nothing ever pushed it to
// the user, and because the display carried no duration, "it'll clear up soon" looked
// like a reasonable read every single time.
//
// Every alert body MUST carry the accumulated duration. "E1 82%" and
// "E1 82% — 8 days" call for completely different decisions; the number does not
// change a mind, the elapsed time does.

import Foundation
import UserNotifications

final class AlertManager: @unchecked Sendable {

    static let shared = AlertManager()

    /// Re-alerting cadence for something that stays confirmed. Repeating hourly
    /// forever trains the user to ignore alerts, which is worse than silence.
    static let escalation: [TimeInterval] = [3600, 86400, 7 * 86400]   // 1h → 1d → 1w
    /// A dismissal buys quiet for this long — then, if still confirmed, it returns.
    /// Dismissal is a judgement that may be wrong; it must be revisitable.
    ///
    /// Overridable via `MACTR_DISMISS_SUPPRESSION` (seconds) so the resurface path can
    /// be verified in minutes instead of waiting a day (§5.6).
    let dismissSuppression: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["MACTR_DISMISS_SUPPRESSION"],
           let v = TimeInterval(s) { return v }
        return 24 * 3600
    }()
    /// Alerts raised within this window are delivered as one notification.
    static let coalesceWindow: TimeInterval = 5

    private struct AlertState {
        var firstAlertedAt: Date
        var lastAlertedAt: Date
        var escalationStep: Int
        var dismissedAt: Date?
        var dismissCount: Int
    }

    private let lock = NSLock()
    private var states: [String: AlertState] = [:]
    private var pending: [WatchItem] = []
    private var flushScheduled = false
    private var authorized = false
    private let queue = DispatchQueue(label: "com.beret21.MacTR.alerts")

    private func key(_ i: WatchItem) -> String { "\(i.kind.rawValue)/\(i.id)" }

    // MARK: Setup

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
                self?.authorized = granted
                if let err { log("[Alert] authorization error: \(err)") }
                log("[Alert] notifications \(granted ? "authorized" : "denied")")
            }
    }

    // MARK: Watchlist callbacks

    func onConfirmed(_ item: WatchItem) {
        let k = key(item)
        let now = Date()
        lock.lock()
        var st = states[k]

        if let existing = st {
            // Suppressed by an explicit dismissal?
            if let d = existing.dismissedAt {
                guard now.timeIntervalSince(d) >= dismissSuppression else {
                    lock.unlock(); return
                }
                // Suppression elapsed and the condition never resolved → resurface,
                // with wording that makes the elapsed time impossible to miss.
                st!.dismissedAt = nil
                states[k] = st
                lock.unlock()
                MetricsLogger.shared.logEvent(.resurface, kind: item.kind.rawValue, id: item.id,
                                              duration: item.duration(now: now))
                enqueue(item, resurfaced: true)
                return
            }
            // Already alerted — only re-alert on the escalation ladder.
            let step = min(existing.escalationStep, AlertManager.escalation.count - 1)
            let due = AlertManager.escalation[step]
            guard now.timeIntervalSince(existing.lastAlertedAt) >= due else {
                lock.unlock(); return
            }
            st!.lastAlertedAt = now
            st!.escalationStep = min(existing.escalationStep + 1, AlertManager.escalation.count - 1)
            states[k] = st
            lock.unlock()
            enqueue(item, resurfaced: false)
            return
        }

        states[k] = AlertState(firstAlertedAt: now, lastAlertedAt: now,
                               escalationStep: 0, dismissedAt: nil, dismissCount: 0)
        lock.unlock()
        enqueue(item, resurfaced: false)
    }

    func onCleared(_ item: WatchItem) {
        lock.lock()
        states.removeValue(forKey: key(item))
        lock.unlock()
    }

    /// Records a dismissal. Dismissal is not information being discarded — it is a
    /// judgement, and it belongs in the event log alongside the condition itself.
    func dismiss(_ item: WatchItem) {
        let k = key(item)
        lock.lock()
        var st = states[k] ?? AlertState(firstAlertedAt: Date(), lastAlertedAt: Date(),
                                         escalationStep: 0, dismissedAt: nil, dismissCount: 0)
        st.dismissedAt = Date()
        st.dismissCount += 1
        states[k] = st
        lock.unlock()
        MetricsLogger.shared.logEvent(.dismiss, kind: item.kind.rawValue, id: item.id,
                                      duration: item.duration(),
                                      detail: ["count": String(st.dismissCount)])
    }

    // MARK: Delivery

    private func enqueue(_ item: WatchItem, resurfaced: Bool) {
        lock.lock()
        pending.append(item)
        let needSchedule = !flushScheduled
        if needSchedule { flushScheduled = true }
        lock.unlock()
        guard needSchedule else { return }
        queue.asyncAfter(deadline: .now() + AlertManager.coalesceWindow) { [weak self] in
            self?.flush(resurfaced: resurfaced)
        }
    }

    private func flush(resurfaced: Bool) {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }

        let (title, body) = compose(batch, resurfaced: resurfaced)
        for item in batch {
            MetricsLogger.shared.logEvent(.alert, kind: item.kind.rawValue, id: item.id,
                                          duration: item.duration(),
                                          detail: ["resurfaced": String(resurfaced)])
        }
        deliver(title: title, body: body)
    }

    /// Multiple simultaneous problems arrive as one notification, not a burst.
    func compose(_ items: [WatchItem], resurfaced: Bool) -> (String, String) {
        let now = Date()
        let longest = items.map { $0.duration(now: now) }.max() ?? 0
        let durText = Draw.formatDurationLong(longest)

        if resurfaced, let first = items.first {
            return ("[MacTR] 무시한 항목이 여전히 지속 중",
                    """
                    이전에 무시하신 "\(describe(first))"이(가) 그 이후로도 계속되고 있습니다.
                    최초 감지: \(Self.stamp(first.since)) · 누적 \(durText)
                    """)
        }

        let cores = items.filter { $0.kind == .core }
        let procs = items.filter { $0.kind == .process }
        let diags = items.filter { $0.kind == .diag }

        var lines: [String] = []
        if !cores.isEmpty {
            let names = cores.map(\.id).joined(separator: ", ")
            lines.append("\(names) 코어가 \(durText)째 \(Int(CPUThresholds.saturated))% 이상입니다.")
        }
        if !procs.isEmpty {
            lines.append("주 소비: " + procs.map { "\($0.id) \($0.detail)" }.joined(separator: ", "))
        }
        if !diags.isEmpty {
            lines.append("관련 신고: " + diags.map { "\($0.id) \($0.detail)" }.joined(separator: ", "))
        }
        if lines.isEmpty, let f = items.first {
            lines.append("\(describe(f)) — \(durText)째 지속")
        }
        return ("[MacTR] 만성 부하 감지", lines.joined(separator: "\n"))
    }

    private func describe(_ i: WatchItem) -> String {
        switch i.kind {
        case .core: return "\(i.id) 코어 포화"
        case .process: return "\(i.id) 고부하"
        case .diag: return "\(i.id) 시스템 신고"
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f.string(from: d)
    }

    private func deliver(title: String, body: String) {
        log("[Alert] \(title) — \(body.replacingOccurrences(of: "\n", with: " / "))")
        // UNUserNotificationCenter only works from a bundled .app (#17). Headless runs
        // print instead, so alert wording stays inspectable without a GUI — os_log is
        // not a reliable channel for this (see §4.4).
        guard Bundle.main.bundleIdentifier != nil else {
            print("\n──── ALERT ────\n\(title)\n\(body)\n───────────────")
            fflush(stdout)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { log("[Alert] delivery failed: \(err)") }
        }
    }
}
