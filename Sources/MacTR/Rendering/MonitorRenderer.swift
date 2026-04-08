// MonitorRenderer.swift — System Monitor 5-panel dashboard
//
// Set 1: CPU | GPU | Memory | Disk | System
// Ported from trcc_monitor.py render_* functions.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
    private let lock = NSLock()

    // Cached snapshots (written by metricsQueue, read by render thread)
    private var _cpu: CPUSnapshot?
    private var _mem: MemorySnapshot?
    private var _gpu: GPUSnapshot?
    private var _disk: DiskSnapshot?
    private var _net: NetworkSnapshot?
    private var _diskIO: DiskIOSnapshot?
    private var _temp: TemperatureSnapshot?
    private var _bat: BatterySnapshot?
    private var _sys: SystemSnapshot?

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

    // Ring buffers for sparklines (last 60 samples = 30 seconds)
    private let sparklineSize = 60
    private var netRxHistory: [Double] = []
    private var netTxHistory: [Double] = []
    private var diskReadHistory: [Double] = []
    private var diskWriteHistory: [Double] = []

    private func pushSample(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > sparklineSize { buffer.removeFirst() }
    }

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        guard !metricsRunning else { return }
        log("[Metrics] Starting collection...")
        metricsRunning = true
        // First pass: prime CPU ticks (deltas will be zero)
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let bat = collector.collectBattery()
        let sys = collector.collectSystem()
        let gpu = collector.collectGPU()
        let disk = collector.collectDisk()
        let net = collector.collectNetwork()
        let diskIO = collector.collectDiskIO()
        let temp = collector.collectTemperature()
        lock.lock()
        _cpu = cpu0; _mem = mem; _bat = bat; _sys = sys
        _gpu = gpu; _disk = disk; _net = net; _diskIO = diskIO; _temp = temp
        lock.unlock()

        // Second pass: get real CPU deltas
        Thread.sleep(forTimeInterval: 0.3)
        let cpu1 = collector.collectCPU()
        lock.lock()
        _cpu = cpu1
        lock.unlock()

        // Start async collection loop
        metricsQueue.async { [weak self] in self?.metricsLoop() }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        metricsRunning = false
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        while metricsRunning {
            // Fast metrics every tick
            let cpu = collector.collectCPU()
            let mem = collector.collectMemory()
            let bat = collector.collectBattery()
            let sys = collector.collectSystem()
            lock.lock()
            _cpu = cpu; _mem = mem; _bat = bat; _sys = sys
            lock.unlock()

            // Slow metrics every 4th tick (~2s)
            slowTick += 1
            if slowTick >= 4 {
                let gpu = collector.collectGPU()
                let disk = collector.collectDisk()
                let net = collector.collectNetwork()
                let diskIO = collector.collectDiskIO()
                let temp = collector.collectTemperature()
                lock.lock()
                _gpu = gpu; _disk = disk; _net = net; _diskIO = diskIO; _temp = temp
                lock.unlock()
                slowTick = 0
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    /// Render with fully simulated data (for screenshots — no real system info)
    func renderSimulated(coreCount: Int) -> CGImage? {
        let fakeCores = (0..<coreCount).map { _ in Double.random(in: 5...95) }
        let cpu = CPUSnapshot(perCore: fakeCores,
                              total: fakeCores.reduce(0, +) / Double(coreCount),
                              loadAvg: (3.5, 4.2, 3.8),
                              pCoreCount: max(coreCount - 2, coreCount * 3 / 4))
        let gb: UInt64 = 1024 * 1024 * 1024
        let mem = MemorySnapshot(
            total: 32 * gb, active: 8 * gb, wired: 4 * gb,
            compressed: 2 * gb, available: 18 * gb,
            swapUsed: 512 * 1024 * 1024, swapTotal: 4 * gb)
        let bat = BatterySnapshot(percent: 85, isCharging: false, isPresent: true)
        let sys = SystemSnapshot(uptimeSeconds: 86400 + 7200 + 1800, processCount: 412)
        let disk = DiskSnapshot(totalGB: 1000, usedGB: 420, freeGB: 580)
        let net = NetworkSnapshot(rxBytesPerSec: 2_500_000, txBytesPerSec: 350_000)
        let diskIO = DiskIOSnapshot(readBytesPerSec: 15_000_000, writeBytesPerSec: 8_000_000)
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let gpu = GPUSnapshot(name: "Apple GPU", cores: 30,
                              deviceUtil: 12, rendererUtil: 8, tilerUtil: 5,
                              memUsedMB: 1280, memAllocMB: 2560)

        // Fill sparklines with random history
        for _ in 0..<sparklineSize {
            pushSample(&netRxHistory, Double.random(in: 500_000...5_000_000))
            pushSample(&netTxHistory, Double.random(in: 100_000...800_000))
            pushSample(&diskReadHistory, Double.random(in: 1_000_000...30_000_000))
            pushSample(&diskWriteHistory, Double.random(in: 500_000...15_000_000))
        }

        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        Draw.gradientBackground(ctx)
        renderCPU(ctx, cpu: cpu, temp: temp)
        renderGPU(ctx, gpu: gpu, temp: temp)
        renderMemory(ctx, mem: mem, net: net)
        renderDisk(ctx, disk: disk, diskIO: diskIO)
        renderSystem(ctx, bat: bat, sys: sys)
        return ctx.makeImage()
    }

    func render() -> CGImage? {
        // Read cached metrics (never blocks — uses latest available values)
        lock.lock()
        guard let cpu = _cpu, let mem = _mem, let gpu = _gpu,
              let disk = _disk, let net = _net, let diskIO = _diskIO,
              let temp = _temp, let bat = _bat, let sys = _sys
        else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Update sparkline histories
        pushSample(&netRxHistory, net.rxBytesPerSec)
        pushSample(&netTxHistory, net.txBytesPerSec)
        pushSample(&diskReadHistory, diskIO.readBytesPerSec)
        pushSample(&diskWriteHistory, diskIO.writeBytesPerSec)

        // Reuse CGContext to prevent CG raster data memory growth
        let w = Layout.width
        let h = Layout.height
        if reusableCtx == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            reusableCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = reusableCtx else { return nil }

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        Draw.gradientBackground(ctx)

        // Panels
        renderCPU(ctx, cpu: cpu, temp: temp)
        renderGPU(ctx, gpu: gpu, temp: temp)
        renderMemory(ctx, mem: mem, net: net)
        renderDisk(ctx, disk: disk, diskIO: diskIO)
        renderSystem(ctx, bat: bat, sys: sys)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    // MARK: - CPU Panel

    private func renderCPU(_ ctx: CGContext, cpu: CPUSnapshot, temp: TemperatureSnapshot) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 20, y: py + 14, font: Fonts.system(24, weight: .bold), color: Color.blue)
        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: cpu.total,
                      color: Color.forPercent(cpu.total),
                      colorDark: Color.forPercentDark(cpu.total), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", cpu.total),
                          cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Per-core bars — E-cores first, then P-cores, shifted down half a row
        let barX = x + 194
        let barW = pw - 218
        let coreCount = cpu.perCore.count
        let bottomLimit = py + ph - 96
        let fontSize: CGFloat = coreCount > 16 ? 12 : (coreCount > 10 ? 14 : 16)
        let barH = coreCount > 16 ? 8 : (coreCount > 10 ? 10 : 10)
        let spacing = min(36, (bottomLimit - py - 18) / max(coreCount, 1))
        let startY = py + 18 + spacing / 2  // shifted down half a row

        let pCoreCount = cpu.pCoreCount
        let eCoreCount = coreCount - pCoreCount

        // Reorder: E-cores first, then P-cores
        for row in 0..<coreCount {
            let by = startY + row * spacing
            if by + Int(fontSize) > bottomLimit { break }

            let coreIndex: Int
            let isECore: Bool
            let label: String
            if row < eCoreCount {
                // E-core rows first
                coreIndex = pCoreCount + row
                isECore = true
                label = "E\(row + 1)"
            } else {
                // P-core rows after
                coreIndex = row - eCoreCount
                isECore = false
                label = "P\(row - eCoreCount + 1)"
            }

            let pct = coreIndex < cpu.perCore.count ? cpu.perCore[coreIndex] : 0
            let barColor = isECore ? Color.cyan : Color.forPercent(pct)

            Draw.text(ctx, label, x: barX, y: by,
                      font: Fonts.system(fontSize), color: isECore ? Color.cyan : Color.textD)
            Draw.bar(ctx, x: barX + 28, y: by + 4, w: barW - 78, h: barH,
                     percent: pct, color: barColor)
            Draw.text(ctx, String(format: "%.0f%%", pct),
                      x: barX + barW - 46, y: by,
                      font: Fonts.system(fontSize), color: Color.textS)
        }

        // Airflow temperature + Load average at panel bottom
        let bottomY = py + ph - 92
        if let cpuTemp = temp.cpuTemp {
            let tempColor = cpuTemp > 65 ? Color.red : (cpuTemp > 50 ? Color.orange : Color.green)
            Draw.text(ctx, "Temp", x: x + 16, y: bottomY,
                      font: Fonts.system(22, weight: .medium), color: Color.textL)
            Draw.text(ctx, String(format: "%.0f°C", cpuTemp),
                      x: x + 76, y: bottomY - 2,
                      font: Fonts.system(30, weight: .bold), color: tempColor)
        }

        let (l1, l5, l15) = cpu.loadAvg
        Draw.text(ctx, String(format: "Load  %.1f / %.1f / %.1f", l1, l5, l15),
                  x: x + 16, y: bottomY + 38,
                  font: Fonts.system(18), color: Color.textD)
    }

    // MARK: - GPU Panel

    private func renderGPU(_ ctx: CGContext, gpu: GPUSnapshot, temp: TemperatureSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth
        let py = Layout.panelY

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.magenta)
        Draw.text(ctx, "GPU", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.magenta)
        if gpu.cores > 0 {
            Draw.text(ctx, "\(gpu.cores) cores", x: x + pw - 95, y: py + 16,
                      font: Fonts.system(18), color: Color.textD)
        }

        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: Double(gpu.deviceUtil),
                      color: Color.magenta, colorDark: Color.magentaD, thickness: 13)
        Draw.centeredText(ctx, "\(gpu.deviceUtil)", cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Utilization bars
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Utilization", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28

        let items: [(String, Int, CGColor)] = [
            ("Device", gpu.deviceUtil, Color.magenta),
            ("Renderer", gpu.rendererUtil, Color.purple),
            ("Tiler", gpu.tilerUtil, Color.cyan),
        ]
        for (label, val, color) in items {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(19), color: Color.textL)
            Draw.text(ctx, "\(val)%", x: rx + rw - 46, y: ry,
                      font: Fonts.system(19), color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: Double(val), color: color)
            ry += 48
        }

        // Memory section
        ry += 4
        Draw.line(ctx, from: CGPoint(x: rx, y: ry),
                  to: CGPoint(x: rx + rw, y: ry),
                  color: Color.border)
        ry += 12
        Draw.text(ctx, "Memory", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28
        Draw.text(ctx, "In Use", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, "\(gpu.memUsedMB) MB", x: rx + rw - 70, y: ry,
                  font: Fonts.system(19), color: Color.textS)
        if gpu.memAllocMB > 0 {
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: Double(gpu.memUsedMB) / Double(gpu.memAllocMB) * 100,
                     color: Color.magenta)
        }
        ry += 48
        Draw.text(ctx, "Allocated", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, "\(gpu.memAllocMB) MB", x: rx + rw - 70, y: ry,
                  font: Fonts.system(19), color: Color.textD)

    }

    // MARK: - Memory Panel

    private func renderMemory(_ ctx: CGContext, mem: MemorySnapshot, net: NetworkSnapshot) {
        let x = Layout.panelX(2)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let totalGB = Double(mem.total) / (1024 * 1024 * 1024)
        let usedGB = Double(mem.total - mem.available) / (1024 * 1024 * 1024)
        let pct = mem.percent

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.green)
        Draw.text(ctx, "MEMORY", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + pw - 75, y: py + 16,
                  font: Fonts.system(18), color: Color.textD)

        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: pct,
                      color: Color.forPercent(pct),
                      colorDark: Color.forPercentDark(pct), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", pct), cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Breakdown
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Breakdown", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28

        let activeGB = Double(mem.active) / (1024 * 1024 * 1024)
        let wiredGB = Double(mem.wired) / (1024 * 1024 * 1024)
        let compressedGB = Double(mem.compressed) / (1024 * 1024 * 1024)
        let availGB = Double(mem.available) / (1024 * 1024 * 1024)

        let items: [(String, Double, CGColor)] = [
            ("Active", activeGB, Color.green),
            ("Wired", wiredGB, Color.orange),
            ("Compressed", compressedGB, Color.purple),
            ("Available", availGB, Color.cyan),
        ]
        for (label, val, color) in items {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(19), color: Color.textL)
            Draw.text(ctx, String(format: "%.1fG", val), x: rx + rw - 52, y: ry,
                      font: Fonts.system(19), color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: val / totalGB * 100, color: color)
            ry += 48
        }

        // Swap
        ry += 4
        Draw.line(ctx, from: CGPoint(x: rx, y: ry),
                  to: CGPoint(x: rx + rw, y: ry),
                  color: Color.border)
        ry += 12
        let swapUsedG = Double(mem.swapUsed) / (1024 * 1024 * 1024)
        let swapTotalG = Double(mem.swapTotal) / (1024 * 1024 * 1024)
        Draw.text(ctx, "Swap", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        let swapText = swapTotalG > 0
            ? String(format: "%.1f / %.0f G", swapUsedG, swapTotalG)
            : "0 G"
        Draw.text(ctx, swapText, x: rx + rw - 90, y: ry,
                  font: Fonts.system(19), color: Color.textD)

        // Network mirror bar chart — same divider/chart size as Disk I/O
        // Shared constants: dividerY at panelBottom - 120, chart 18px below, 90px tall
        let netDividerY = py + Layout.panelHeight - 120
        let netChartY = netDividerY + 22  // label(18) + gap(4)
        let netChartH = py + Layout.panelHeight - netChartY - 6

        Draw.line(ctx, from: CGPoint(x: x + 16, y: netDividerY),
                  to: CGPoint(x: x + pw - 16, y: netDividerY), color: Color.border)
        Draw.text(ctx, "Network", x: x + 16, y: netDividerY + 4,
                  font: Fonts.system(17, weight: .medium), color: Color.textL)
        Draw.mirrorBarChart(ctx,
            topValues: netRxHistory, bottomValues: netTxHistory,
            x: x + 16, y: netChartY, w: pw - 32, h: netChartH,
            topColor: Color.cyan, bottomColor: Color.orange,
            topLabel: "↓", bottomLabel: "↑",
            topCurrent: Draw.formatBytesPerSec(net.rxBytesPerSec),
            bottomCurrent: Draw.formatBytesPerSec(net.txBytesPerSec))
    }

    // MARK: - Disk Panel

    private func renderDisk(_ ctx: CGContext, disk: DiskSnapshot, diskIO: DiskIOSnapshot) {
        let x = Layout.panelX(3)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let dpct = disk.percent

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.orange)
        Draw.text(ctx, "DISK", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.orange)
        Draw.text(ctx, String(format: "%.0f GB", disk.totalGB), x: x + pw - 85, y: py + 16,
                  font: Fonts.system(18), color: Color.textD)

        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: dpct,
                      color: Color.forPercent(dpct),
                      colorDark: Color.forPercentDark(dpct), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", dpct), cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Details
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Storage", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 30

        let diskItems: [(String, Double, CGColor)] = [
            ("Used", disk.usedGB, Color.orange),
            ("Free", disk.freeGB, Color.green),
        ]
        for (label, val, color) in diskItems {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(22), color: Color.textL)
            Draw.text(ctx, String(format: "%.0f GB", val), x: rx + rw - 80, y: ry,
                      font: Fonts.system(22), color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 30, w: rw, h: 12,
                     percent: val / disk.totalGB * 100, color: color)
            ry += 62
        }

        // Disk I/O mirror bar chart — same divider/chart size as Network
        let ioDividerY = py + Layout.panelHeight - 120  // same as Network
        let ioChartY = ioDividerY + 22
        let ioX = x + 12
        let ioW = pw - 24
        let ioChartH = py + Layout.panelHeight - ioChartY - 6

        Draw.line(ctx, from: CGPoint(x: ioX, y: ioDividerY),
                  to: CGPoint(x: ioX + ioW, y: ioDividerY), color: Color.border)
        Draw.text(ctx, "I/O", x: ioX, y: ioDividerY + 4,
                  font: Fonts.system(17, weight: .medium), color: Color.textL)
        Draw.mirrorBarChart(ctx,
            topValues: diskReadHistory, bottomValues: diskWriteHistory,
            x: ioX, y: ioChartY, w: ioW, h: ioChartH,
            topColor: Color.green, bottomColor: Color.orange,
            topLabel: "R", bottomLabel: "W",
            topCurrent: Draw.formatBytesPerSec(diskIO.readBytesPerSec),
            bottomCurrent: Draw.formatBytesPerSec(diskIO.writeBytesPerSec))
    }

    // MARK: - System Panel

    private func renderSystem(_ ctx: CGContext, bat: BatterySnapshot, sys: SystemSnapshot) {
        let x = Layout.panelX(4)
        let pw = Layout.panelWidth
        let py = Layout.panelY

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.cyan)
        Draw.text(ctx, "SYSTEM", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)

        // Clock
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        Draw.text(ctx, timeStr, x: x + 16, y: py + 48,
                  font: Fonts.system(56, weight: .medium), color: Color.textW)

        // Date
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        Draw.text(ctx, dateStr, x: x + 20, y: py + 130,
                  font: Fonts.system(24), color: Color.textS)

        formatter.dateFormat = "EEEE"
        let dayStr = formatter.string(from: Date())
        Draw.text(ctx, dayStr, x: x + 20, y: py + 160,
                  font: Fonts.system(20), color: Color.textL)

        // Divider
        Draw.line(ctx, from: CGPoint(x: x + 16, y: Layout.height - (py + 192)),
                  to: CGPoint(x: x + pw - 16, y: Layout.height - (py + 192)),
                  color: Color.border)

        // System info
        var ry = py + 208
        let rx = x + 20
        let rw = pw - 40

        // Uptime
        let hours = sys.uptimeSeconds / 3600
        let mins = (sys.uptimeSeconds % 3600) / 60
        Draw.text(ctx, "Uptime", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, "\(hours)h \(mins)m", x: rx + rw - 80, y: ry,
                  font: Fonts.system(19), color: Color.textS)
        ry += 32

        // Processes
        Draw.text(ctx, "Processes", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, "\(sys.processCount)", x: rx + rw - 55, y: ry,
                  font: Fonts.system(19), color: Color.textS)
        ry += 32

        // Load average (from CPU — re-collect quickly)
        var loadavg: [Double] = [0, 0, 0]
        getloadavg(&loadavg, 3)
        Draw.text(ctx, "Load Avg", x: rx, y: ry,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, String(format: "%.1f / %.1f / %.1f", loadavg[0], loadavg[1], loadavg[2]),
                  x: rx + rw - 125, y: ry,
                  font: Fonts.system(19), color: Color.textS)
        ry += 32

        // Battery
        if bat.isPresent {
            let color = bat.isCharging ? Color.green : (bat.percent > 20 ? Color.orange : Color.red)
            let status = "\(bat.percent)% \(bat.isCharging ? "Charging" : "Battery")"
            Draw.text(ctx, "Battery", x: rx, y: ry,
                      font: Fonts.system(19), color: Color.textL)
            Draw.text(ctx, status, x: rx + rw - 130, y: ry,
                      font: Fonts.system(19), color: color)
            ry += 26
            Draw.bar(ctx, x: rx, y: ry, w: rw, h: 10,
                     percent: Double(bat.percent), color: color)
        }
    }
}
