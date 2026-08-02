// ScanScheduler.swift — adaptive pacing for the expensive process scan
//
// A monitor must not become a meaningful part of what it measures. Measured on this
// machine: enumerating ~850 processes (proc_listpids + proc_pidinfo each) costs about
// 7ms, so at the original fixed 2s cadence it burned ~0.36% of a core continuously —
// small, but it was also the single most expensive thing MacTR did on a timer, and it
// ran just as hard when there was nothing to look at.
//
// Everything else stays fast, because everything else is genuinely cheap: per-core CPU
// is a single host_processor_info() call, and the diag directory is just a listing.
// Only the full process walk is paced. Cheap observation always, expensive work rarely.
//
// The pacing runs INVERTED relative to naive backpressure. Backing off when load is
// high would mean seeing least at the exact moment it matters most. Instead the scan
// speeds up when something is saturated (there is now a culprit worth naming) and
// decays back down once it clears.

import Foundation

enum ScanIntensity: String, CaseIterable, Sendable {
    case powerSaver     // fixed slow — minimum footprint
    case standard       // adaptive: idle slow, tighten on saturation, decay on release
    case precise        // fixed fast — diagnosis

    var label: String {
        switch self {
        case .powerSaver: return "절전"
        case .standard:   return "표준"
        case .precise:    return "정밀"
        }
    }

    var detail: String {
        switch self {
        case .powerSaver: return "120초 고정 — 부하 최소"
        case .standard:   return "자동 60↔2초 — 포화 시 조이고 해소되면 완화"
        case .precise:    return "2초 고정 — 진단용"
        }
    }
}

final class ScanScheduler: @unchecked Sendable {

    static let shared = ScanScheduler()

    /// Decay ladder used after saturation clears: tighten instantly, relax gradually.
    /// Stepping straight back to 60s would blind the scan during the settling period,
    /// which is when a load is most likely to come back.
    private static let ladder: [TimeInterval] = [2, 5, 15, 60]
    private static let powerSaverInterval: TimeInterval = 120
    private static let preciseInterval: TimeInterval = 2
    private static let defaultsKey = "ScanIntensity"

    private let lock = NSLock()
    private var rung = ScanScheduler.ladder.count - 1   // start relaxed
    private var lastScan = Date.distantPast
    /// Set while the user has the menu open — they are looking right now, so the data
    /// under their eyes should be current regardless of the ambient pace.
    private var attentionUntil = Date.distantPast

    // MARK: Preference

    var intensity: ScanIntensity {
        get {
            let raw = UserDefaults.standard.string(forKey: ScanScheduler.defaultsKey) ?? ""
            return ScanIntensity(rawValue: raw) ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ScanScheduler.defaultsKey)
            lock.lock(); rung = 0; lastScan = .distantPast; lock.unlock()  // apply at once
            log("[Scan] intensity → \(newValue.label) (\(newValue.detail))")
        }
    }

    /// Called when the user opens the menu bar menu.
    func noteUserAttention(seconds: TimeInterval = 30) {
        lock.lock()
        attentionUntil = Date().addingTimeInterval(seconds)
        rung = 0
        lock.unlock()
    }

    // MARK: Pacing

    /// Current interval, for display and for logging what the policy is doing.
    var currentInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return intervalLocked()
    }

    private func intervalLocked() -> TimeInterval {
        switch intensity {
        case .powerSaver: return ScanScheduler.powerSaverInterval
        case .precise:    return ScanScheduler.preciseInterval
        case .standard:
            if Date() < attentionUntil { return ScanScheduler.ladder[0] }
            return ScanScheduler.ladder[min(rung, ScanScheduler.ladder.count - 1)]
        }
    }

    /// Ask whether the expensive scan should run now.
    /// `saturated` is derived from the cheap per-core sample that runs every tick, so
    /// the decision to look harder costs nothing to make.
    func shouldScan(saturated: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Tightening is immediate; relaxing is earned. The rung only advances after a
        // scan actually happens, so the ladder is walked 2 → 5 → 15 → 60 with a real
        // observation at each step. Advancing it on elapsed time instead would skip
        // straight from 2s to 60s and leave the settling period unobserved — which is
        // exactly when a load tends to come back.
        if intensity == .standard, saturated { rung = 0 }

        guard now.timeIntervalSince(lastScan) >= intervalLocked() else { return false }
        lastScan = now
        if intensity == .standard, !saturated, Date() >= attentionUntil {
            rung = min(rung + 1, ScanScheduler.ladder.count - 1)
        }
        return true
    }
}
