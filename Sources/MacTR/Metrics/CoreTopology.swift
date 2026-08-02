// CoreTopology.swift — ask the hardware which cores are which
//
// Core type is read from the IODeviceTree at startup instead of being inferred from
// core counts. Every CPU node there carries `logical-cpu-id` and `cluster-type`
// ("E" or "P"), and the logical id is the same index `host_processor_info()` uses —
// so the mapping is stated by the machine rather than assumed by us.
//
// This replaces the assumption that caused four months of mislabeled cores. The old
// code derived positions from `hw.perflevel0.logicalcpu` (a COUNT) and guessed that
// performance cores came first, because perflevel *0* is named "Performance". That
// number is a performance-tier rank, not an array offset; on Apple Silicon the array
// actually starts with the efficiency cluster, so every row was wrong.
//
// Reading the topology also makes the code portable: an M2/M3/M4, a different core
// split, or a future part that orders its clusters differently all work without a
// code change, because nothing here encodes a layout.

import Darwin
import Foundation
import IOKit

enum CoreType: Sendable, Equatable {
    case efficiency
    case performance
}

enum CoreTopology {

    /// Core type per logical CPU index — the same index used by `host_processor_info()`.
    /// Resolved once; the topology cannot change while the machine is running.
    static let types: [CoreType] = detect()

    static var eCoreIndices: [Int] { types.indices.filter { types[$0] == .efficiency } }
    static var pCoreIndices: [Int] { types.indices.filter { types[$0] == .performance } }
    static var eCoreCount: Int { eCoreIndices.count }
    static var pCoreCount: Int { pCoreIndices.count }

    /// Display order: efficiency cores first, then performance — a presentation choice,
    /// kept separate from where the cores actually sit in the array.
    /// Returns (arrayIndex, label, isEfficiency) per row.
    static func displayRows() -> [(index: Int, label: String, isEfficiency: Bool)] {
        var rows: [(Int, String, Bool)] = []
        for (n, i) in eCoreIndices.enumerated() { rows.append((i, "E\(n + 1)", true)) }
        for (n, i) in pCoreIndices.enumerated() { rows.append((i, "P\(n + 1)", false)) }
        return rows.map { (index: $0.0, label: $0.1, isEfficiency: $0.2) }
    }

    /// Label for a raw array index, e.g. index 0 → "E1" on Apple Silicon.
    static func label(forIndex i: Int) -> String {
        if let n = eCoreIndices.firstIndex(of: i) { return "E\(n + 1)" }
        if let n = pCoreIndices.firstIndex(of: i) { return "P\(n + 1)" }
        return "C\(i + 1)"
    }

    // MARK: - Detection

    private static func detect() -> [CoreType] {
        if let dt = fromDeviceTree() {
            let e = dt.filter { $0 == .efficiency }.count
            log("[Topology] device tree: \(dt.count) cores, \(e)E + \(dt.count - e)P, "
                + "order=\(dt.map { $0 == .efficiency ? "E" : "P" }.joined())")
            return dt
        }
        let fb = fromSysctl()
        log("[Topology] device tree unavailable — falling back to sysctl counts "
            + "(\(fb.filter { $0 == .efficiency }.count)E + \(fb.filter { $0 == .performance }.count)P, "
            + "efficiency-first assumed)")
        return fb
    }

    /// Authoritative path: IODeviceTree:/cpus children expose cluster-type per core.
    private static func fromDeviceTree() -> [CoreType]? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var map: [Int: CoreType] = [:]
        var child = IOIteratorNext(iter)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iter) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let type = clusterType(dict["cluster-type"]),
                  let id = intValue(dict["logical-cpu-id"])
            else { continue }
            map[id] = type
        }

        // Only trust a complete, contiguous 0..<n mapping — a partial read would
        // silently shift labels, which is the exact failure being designed out.
        guard let maxID = map.keys.max(), map.count == maxID + 1 else { return nil }
        let ncpu = sysctlInt("hw.logicalcpu") ?? map.count
        guard map.count == ncpu else { return nil }
        return (0...maxID).compactMap { map[$0] }
    }

    /// Fallback for Intel or if the device tree is unreadable. Counts are known;
    /// order is not, so this keeps the empirically observed Apple Silicon layout
    /// (efficiency first) and says so in the log rather than pretending to know.
    private static func fromSysctl() -> [CoreType] {
        let total = sysctlInt("hw.logicalcpu") ?? 1
        let perf = sysctlInt("hw.perflevel0.logicalcpu") ?? total
        let eff = max(total - perf, 0)
        return Array(repeating: .efficiency, count: eff)
             + Array(repeating: .performance, count: total - eff)
    }

    // MARK: - Property decoding

    /// `cluster-type` arrives as raw device-tree data holding "E" or "P".
    private static func clusterType(_ value: Any?) -> CoreType? {
        var s: String?
        if let d = value as? Data { s = String(decoding: d, as: UTF8.self) }
        else if let t = value as? String { s = t }
        guard let c = s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).first
        else { return nil }
        switch c {
        case "E", "e": return .efficiency
        case "P", "p": return .performance
        default: return nil
        }
    }

    /// Device-tree integers appear as NSNumber or little-endian raw data.
    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Data, !d.isEmpty {
            var v = 0
            for (i, byte) in d.prefix(8).enumerated() { v |= Int(byte) << (8 * i) }
            return v
        }
        return nil
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0, v > 0 else { return nil }
        return Int(v)
    }
}
