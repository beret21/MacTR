// SystemMetricsCollector.swift — Native macOS system metrics collection
//
// Replaces Python psutil calls with native Mach/IOKit/sysctl APIs.
// All metrics are collected synchronously — caller should run off main thread.

import CThermalSensor
import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Data Structures

struct CPUSnapshot: Sendable {
    let perCore: [Double]  // percentage per core
    let total: Double      // average percentage
    let loadAvg: (Double, Double, Double)
    let pCoreCount: Int    // performance cores (rest are efficiency)
}

struct MemorySnapshot: Sendable {
    let total: UInt64      // bytes
    let active: UInt64
    let wired: UInt64
    let compressed: UInt64
    let available: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    var percent: Double { Double(total - available) / Double(total) * 100 }
}

struct GPUSnapshot: Sendable {
    let name: String
    let cores: Int
    let deviceUtil: Int    // percentage
    let rendererUtil: Int
    let tilerUtil: Int
    let memUsedMB: Int
    let memAllocMB: Int
}

struct DiskSnapshot: Sendable {
    let totalGB: Double
    let usedGB: Double
    let freeGB: Double
    var percent: Double { usedGB / totalGB * 100 }
}

struct NetworkSnapshot: Sendable {
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

struct DiskIOSnapshot: Sendable {
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
}

struct TemperatureSnapshot: Sendable {
    let cpuTemp: Double?       // °C, nil if unavailable
    let gpuTemp: Double?       // °C, nil if unavailable
    let thermalState: Int      // 0=nominal, 1=fair, 2=serious, 3=critical
}

struct BatterySnapshot: Sendable {
    let percent: Int
    let isCharging: Bool
    let isPresent: Bool
}

struct SystemSnapshot: Sendable {
    let uptimeSeconds: Int
    let processCount: Int
}

// MARK: - Collector

final class SystemMetricsCollector: @unchecked Sendable {

    // Previous CPU ticks for delta calculation
    private var prevTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    // Previous network bytes for delta calculation
    private var prevNetRx: UInt64 = 0
    private var prevNetTx: UInt64 = 0
    private var prevNetTime: Date?

    // Previous disk IO bytes for delta calculation
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var prevDiskTime: Date?

    // SMC connection for temperature
    private var smcConn: io_connect_t = 0
    private var smcOpened = false
    private var smcLogOnce = true

    // MARK: - CPU

    func collectCPU() -> CPUSnapshot {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPU, &cpuInfo, &numCPUInfo)

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUSnapshot(perCore: [], total: 0, loadAvg: (0, 0, 0), pCoreCount: 0)
        }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<Int32>.stride))
        }

        var perCore: [Double] = []
        var newTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

        for i in 0..<Int(numCPU) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])

            newTicks.append((user, system, idle, nice))

            if i < prevTicks.count {
                let du = user - prevTicks[i].user
                let ds = system - prevTicks[i].system
                let di = idle - prevTicks[i].idle
                let dn = nice - prevTicks[i].nice
                let total = du + ds + di + dn
                let pct = total > 0 ? Double(du + ds + dn) / Double(total) * 100 : 0
                perCore.append(pct)
            } else {
                perCore.append(0)
            }
        }

        prevTicks = newTicks

        let total = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)

        var loadavg: [Double] = [0, 0, 0]
        getloadavg(&loadavg, 3)

        // P-core count via sysctl (Apple Silicon)
        var pCores: Int32 = 0
        var pSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &pSize, nil, 0)
        // If sysctl fails (Intel), assume all cores are P-cores
        let pCount = pCores > 0 ? Int(pCores) : perCore.count

        return CPUSnapshot(
            perCore: perCore, total: total,
            loadAvg: (loadavg[0], loadavg[1], loadavg[2]),
            pCoreCount: pCount)
    }

    // MARK: - Memory

    func collectMemory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let pageSize = UInt64(getpagesize())

        guard result == KERN_SUCCESS else {
            return MemorySnapshot(total: 0, active: 0, wired: 0, compressed: 0,
                                  available: 0, swapUsed: 0, swapTotal: 0)
        }

        // Total RAM via sysctl
        var totalRAM: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalRAM, &size, nil, 0)

        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let available = free + inactive

        // Swap via sysctl
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)

        return MemorySnapshot(
            total: totalRAM, active: active, wired: wired,
            compressed: compressed, available: available,
            swapUsed: UInt64(swapUsage.xsu_used),
            swapTotal: UInt64(swapUsage.xsu_total))
    }

    // MARK: - GPU (via ioreg)

    func collectGPU() -> GPUSnapshot {
        var result = GPUSnapshot(
            name: "GPU", cores: 0, deviceUtil: 0, rendererUtil: 0,
            tilerUtil: 0, memUsedMB: 0, memAllocMB: 0)

        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }

            // GPU stats are inside "PerformanceStatistics" sub-dictionary
            let perfStats = dict["PerformanceStatistics"] as? [String: Any] ?? dict

            let cores = dict["gpu-core-count"] as? Int ?? 0
            let device = perfStats["Device Utilization %"] as? Int ?? 0
            let renderer = perfStats["Renderer Utilization %"] as? Int ?? 0
            let tiler = perfStats["Tiler Utilization %"] as? Int ?? 0
            let memUsed = (perfStats["In use system memory"] as? Int ?? 0) / (1024 * 1024)
            let memAlloc = (perfStats["Alloc system memory"] as? Int ?? 0) / (1024 * 1024)

            let gen = dict["gpu_gen"] as? Int ?? 0
            let name = (gen > 0 && cores > 0)
                ? "Apple M-series (G\(gen), \(cores) cores)"
                : "GPU"

            result = GPUSnapshot(
                name: name, cores: cores, deviceUtil: device,
                rendererUtil: renderer, tilerUtil: tiler,
                memUsedMB: memUsed, memAllocMB: memAlloc)

            break  // Use first accelerator
        }

        return result
    }

    // MARK: - Disk (APFS container via diskutil)

    func collectDisk() -> DiskSnapshot {
        // Try APFS container first
        if let apfs = apfsContainerUsage() { return apfs }

        // Fallback: statvfs
        var stat = statvfs()
        guard statvfs("/", &stat) == 0 else {
            return DiskSnapshot(totalGB: 0, usedGB: 0, freeGB: 0)
        }
        let total = Double(stat.f_blocks) * Double(stat.f_frsize) / 1e9
        let free = Double(stat.f_bavail) * Double(stat.f_frsize) / 1e9
        return DiskSnapshot(totalGB: total, usedGB: total - free, freeGB: free)
    }

    private func apfsContainerUsage() -> DiskSnapshot? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["apfs", "list"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse: "Size (Capacity Ceiling):      994662584320 B"
        // Parse: "Capacity In Use By Volumes:   627354714112 B"
        guard let capMatch = output.range(of: #"Size \(Capacity Ceiling\):\s+([\d,]+)\s+B"#,
                                           options: .regularExpression),
              let usedMatch = output.range(of: #"Capacity In Use By Volumes:\s+([\d,]+)\s+B"#,
                                            options: .regularExpression)
        else { return nil }

        let capStr = String(output[capMatch])
            .replacingOccurrences(of: #"[^\d]"#, with: "", options: .regularExpression)
        let usedStr = String(output[usedMatch])
            .replacingOccurrences(of: #"[^\d]"#, with: "", options: .regularExpression)

        guard let totalB = Double(capStr), let usedB = Double(usedStr) else { return nil }

        let totalGB = totalB / (1024 * 1024 * 1024)
        let usedGB = usedB / (1024 * 1024 * 1024)

        return DiskSnapshot(totalGB: totalGB, usedGB: usedGB, freeGB: totalGB - usedGB)
    }

    // MARK: - Battery

    func collectBattery() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              let first = list.first
        else {
            return BatterySnapshot(percent: 0, isCharging: false, isPresent: false)
        }

        let desc = IOPSGetPowerSourceDescription(info, first as CFTypeRef)?
            .takeUnretainedValue() as? [String: Any] ?? [:]

        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        return BatterySnapshot(percent: percent, isCharging: charging, isPresent: true)
    }

    // MARK: - System

    func collectSystem() -> SystemSnapshot {
        // Uptime via sysctl kern.boottime
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        let uptime = Int(Date().timeIntervalSince1970) - Int(boottime.tv_sec)

        // Process count
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var procSize: Int = 0
        sysctl(&mib, 3, nil, &procSize, nil, 0)
        let count = procSize / MemoryLayout<kinfo_proc>.size

        return SystemSnapshot(uptimeSeconds: uptime, processCount: count)
    }

    // MARK: - Network Traffic (sysctl — no subprocess, 64-bit counters)

    func collectNetwork() -> NetworkSnapshot {
        let now = Date()
        let (totalRx, totalTx) = sysctlNetworkBytes()

        var rxPerSec: Double = 0
        var txPerSec: Double = 0

        if let prevTime = prevNetTime, prevNetRx > 0 {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 {
                let dRx = totalRx > prevNetRx ? totalRx - prevNetRx : 0
                let dTx = totalTx > prevNetTx ? totalTx - prevNetTx : 0
                rxPerSec = Double(dRx) / elapsed
                txPerSec = Double(dTx) / elapsed
            }
        }

        prevNetRx = totalRx
        prevNetTx = totalTx
        prevNetTime = now

        return NetworkSnapshot(rxBytesPerSec: rxPerSec, txBytesPerSec: txPerSec)
    }

    /// Read 64-bit network byte counters via sysctl NET_RT_IFLIST2 (no subprocess).
    private func sysctlNetworkBytes() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        sysctl(&mib, 6, nil, &len, nil, 0)
        guard len > 0 else { return (0, 0) }

        var buf = [UInt8](repeating: 0, count: len)
        sysctl(&mib, 6, &buf, &len, nil, 0)

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var offset = 0

        while offset < len {
            let (msgLen, msgType) = buf.withUnsafeBufferPointer { ptr in
                let p = (ptr.baseAddress! + offset).withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
                return (Int(p.ifm_msglen), Int32(p.ifm_type))
            }
            guard msgLen > 0 else { break }

            if msgType == RTM_IFINFO2 {
                let data = buf.withUnsafeBufferPointer { ptr in
                    (ptr.baseAddress! + offset).withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee.ifm_data }
                }
                if data.ifi_type != 24 {  // skip loopback
                    totalRx += data.ifi_ibytes
                    totalTx += data.ifi_obytes
                }
            }

            offset += msgLen
        }
        return (totalRx, totalTx)
    }

    // MARK: - Disk I/O (IOKit disk stats)

    func collectDiskIO() -> DiskIOSnapshot {
        let now = Date()
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        // Use IOKit to get disk statistics
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return DiskIOSnapshot(readBytesPerSec: 0, writeBytesPerSec: 0) }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any]
            else { continue }

            if let rb = stats["Bytes (Read)"] as? UInt64 { totalRead += rb }
            if let wb = stats["Bytes (Write)"] as? UInt64 { totalWrite += wb }
        }

        var readPerSec: Double = 0
        var writePerSec: Double = 0

        if let prevTime = prevDiskTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 && prevDiskRead > 0 {
                if totalRead >= prevDiskRead {
                    readPerSec = Double(totalRead - prevDiskRead) / elapsed
                }
                if totalWrite >= prevDiskWrite {
                    writePerSec = Double(totalWrite - prevDiskWrite) / elapsed
                }
            }
        }

        prevDiskRead = totalRead
        prevDiskWrite = totalWrite
        prevDiskTime = now

        return DiskIOSnapshot(readBytesPerSec: readPerSec, writeBytesPerSec: writePerSec)
    }

    // MARK: - Temperature (SMC)

    func collectTemperature() -> TemperatureSnapshot {
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue

        var cpuTemp: Double? = nil
        var gpuTemp: Double? = nil

        // Primary: IOHIDEventSystemClient (works on all Apple Silicon without sudo)
        var hidCpu: Double = -1
        var hidGpu: Double = -1
        readThermalSensors(&hidCpu, &hidGpu)
        if hidCpu > 0 { cpuTemp = hidCpu }
        if hidGpu > 0 { gpuTemp = hidGpu }
        if smcLogOnce {
            log("[Temp] HID: CPU=\(hidCpu > 0 ? String(format: "%.1f°C", hidCpu) : "N/A"), GPU=\(hidGpu > 0 ? String(format: "%.1f°C", hidGpu) : "N/A")")
        }

        // Fallback: SMC keys (for Intel or if HID fails)
        if cpuTemp == nil || gpuTemp == nil {
            if !smcOpened { openSMC() }
        }

        if smcOpened && (cpuTemp == nil || gpuTemp == nil) {
            // Apple Silicon CPU temperature keys (M1/M1 Pro/M2/M3/M4/M5)
            // Try all known keys — first valid reading wins
            let cpuKeys = [
                // M1/M1 Pro/M1 Max
                "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P",
                // M2/M2 Pro/M2 Max
                "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
                // M3/M3 Pro
                "Te05", "Te0L", "Te0P", "Tf04", "Tf09", "Tf0A", "Tf0D",
                // M4
                "Tp0V", "Tp0Y", "Tp0e",
                // M5
                "Tp00", "Tp04", "Tp08", "Tp0C",
                // Intel fallback
                "Tc0p", "Tc0c",
            ]
            // Average all valid CPU temp readings for accuracy (only if HID failed)
            if cpuTemp == nil {
                var cpuTemps: [(String, Double)] = []
                for key in cpuKeys {
                    if let t = readSMCTemp(key), t > 10 && t < 120 {
                        cpuTemps.append((key, t))
                    }
                }
                if !cpuTemps.isEmpty {
                    cpuTemp = cpuTemps.map(\.1).reduce(0, +) / Double(cpuTemps.count)
                    if smcLogOnce {
                        log("[SMC] CPU temps: \(cpuTemps.map { "\($0.0)=\(String(format: "%.1f", $0.1))°C" }.joined(separator: ", "))")
                    }
                }
            }

            // GPU temperature keys
            let gpuKeys = [
                // M1/M1 Pro
                "Tg05", "Tg0D", "Tg0L", "Tg0T",
                // M2
                "Tg0f", "Tg0j",
                // M3
                "Tf44", "Tf49", "Tf4A", "Tf4D",
                // M4
                "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K",
                // M5
                "Tg0U", "Tg0X", "Tg0d", "Tg0g",
                // Intel fallback
                "Tg0p", "Tg0d",
            ]
            if gpuTemp == nil {
                var gpuTemps: [(String, Double)] = []
                for key in gpuKeys {
                    if let t = readSMCTemp(key), t > 10 && t < 120 {
                        gpuTemps.append((key, t))
                    }
                }
                if !gpuTemps.isEmpty {
                    gpuTemp = gpuTemps.map(\.1).reduce(0, +) / Double(gpuTemps.count)
                    if smcLogOnce {
                        log("[SMC] GPU temps: \(gpuTemps.map { "\($0.0)=\(String(format: "%.1f", $0.1))°C" }.joined(separator: ", "))")
                    }
                }
            }
            smcLogOnce = false
        }

        return TemperatureSnapshot(cpuTemp: cpuTemp, gpuTemp: gpuTemp, thermalState: thermalState)
    }

    // MARK: - SMC Helpers

    private func openSMC() {
        let matching = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        if IOServiceOpen(service, mach_task_self_, 0, &smcConn) == KERN_SUCCESS {
            smcOpened = true
        }
    }

    // SMCKeyData_t matches the Stats app's struct layout (github.com/exelban/stats)
    private struct SMCKeyData_t {
        struct vers_t {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        struct LimitData_t {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }
        struct keyInfo_t {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var vers = vers_t()
        var pLimitData = LimitData_t()
        var keyInfo = keyInfo_t()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) | UInt32(c) }
        return r
    }

    private func smcCall(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(smcConn, 2, &input, inputSize, &output, &outputSize)
    }

    private func readSMCTemp(_ key: String) -> Double? {
        guard smcOpened else { return nil }

        // Step 1: Get key info
        var ki = SMCKeyData_t()
        var ko = SMCKeyData_t()
        ki.key = fourCC(key)
        ki.data8 = 9  // kSMCGetKeyInfo
        guard smcCall(&ki, &ko) == KERN_SUCCESS else { return nil }

        // Step 2: Read value
        var ri = SMCKeyData_t()
        var ro = SMCKeyData_t()
        ri.key = fourCC(key)
        ri.keyInfo.dataSize = ko.keyInfo.dataSize
        ri.data8 = 5  // kSMCReadKey
        guard smcCall(&ri, &ro) == KERN_SUCCESS else { return nil }

        let b = ro.bytes
        let dt = ko.keyInfo.dataType
        let t0 = UInt8((dt >> 24) & 0xFF)
        let t1 = UInt8((dt >> 16) & 0xFF)
        let t2 = UInt8((dt >> 8) & 0xFF)
        let t3 = UInt8(dt & 0xFF)

        // "flt " (0x666C7420) = IEEE float
        if (t0, t1, t2, t3) == (0x66, 0x6C, 0x74, 0x20) {
            let raw = (UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3)
            return Double(Float(bitPattern: raw))
        }
        // "sp78" = signed 7.8 fixed point (value / 256)
        if (t0, t1, t2, t3) == (0x73, 0x70, 0x37, 0x38) {
            return Double(Int16(bigEndian: Int16(UInt16(b.0) << 8 | UInt16(b.1)))) / 256.0
        }
        // "sp87" = signed 8.7 fixed point (value / 128)
        if (t0, t1, t2, t3) == (0x73, 0x70, 0x38, 0x37) {
            return Double(Int16(bigEndian: Int16(UInt16(b.0) << 8 | UInt16(b.1)))) / 128.0
        }
        // "ui8 "
        if (t0, t1, t2, t3) == (0x75, 0x69, 0x38, 0x20) {
            return Double(b.0)
        }
        return nil
    }
}
