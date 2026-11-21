// AppState.swift — App-wide state management
//
// USB I/O runs entirely on a background queue. Only UI state updates
// dispatch to @MainActor. This prevents USB timeouts from blocking
// the main thread (which causes macOS rainbow spinner + keyboard freeze).

import AppKit
import Foundation
import Observation

// MARK: - Display Set

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

enum DisplaySet: String, CaseIterable, Identifiable, Sendable {
    case systemMonitor = "System Monitor"

    var id: String { rawValue }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    // Connection (UI-facing)
    var isConnected = false
    var deviceInfo: DeviceInfo?
    var statusMessage = "Disconnected"

    // Display
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int = 5
    var refreshInterval: Double = AppState.savedRefreshInterval()
    var rotateDisplay: Bool = false

    /// Render interval ("Refresh"), persisted across launches. Default 1.0s (was 0.5s) —
    /// the clock is 1s-resolution. Only rendering/encoding follows this; USB frames are
    /// still sent every 0.5s (cached JPEG re-sent) so the LCD never blanks.
    nonisolated static let refreshIntervalKey = "refreshInterval"
    nonisolated static let refreshIntervalChoices: [Double] = [0.5, 1.0, 2.0]
    nonisolated static let defaultRefreshInterval: Double = 1.0

    nonisolated static func savedRefreshInterval() -> Double {
        let v = UserDefaults.standard.double(forKey: refreshIntervalKey)  // 0 when unset
        return refreshIntervalChoices.contains(v) ? v : defaultRefreshInterval
    }

    // Metrics (for menu bar display)
    var frameCount = 0
    var lastFrameSize = 0

    // MARK: - Internal

    private var engine: DisplayEngine?

    // MARK: - Lifecycle

    func start() {
        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.isConnected
                self.isConnected = status.connected
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                    NotificationCenter.default.post(name: .deviceStateChanged, object: nil)
                }
            }
        }
        engine = eng
        eng.start(set: currentSet, brightness: brightness, interval: refreshInterval, rotate: rotateDisplay)
    }

    func stop() {
        engine?.stop()
        engine = nil
        isConnected = false
        statusMessage = "Stopped"
    }

    func connect() {
        engine?.reconnect()
    }

    func disconnect() {
        engine?.stop()
        isConnected = false
        statusMessage = "Disconnected"
        frameCount = 0
    }

    /// Called when user changes display set, brightness, or interval
    func applySettings() {
        UserDefaults.standard.set(refreshInterval, forKey: AppState.refreshIntervalKey)
        engine?.updateSettings(set: currentSet, brightness: brightness, interval: refreshInterval, rotate: rotateDisplay)
    }
}

// MARK: - Engine Status

struct EngineStatus: Sendable {
    let connected: Bool
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")
    private var device: USBDevice?
    private var hotplug: USBHotplug?
    private var running = false
    private var frameCount = 0
    private var lastFrameSize = 0

    // Settings (atomically accessed)
    private var currentSet: DisplaySet = .systemMonitor
    private var brightness: Int = 5
    private var interval: Double = AppState.defaultRefreshInterval
    private var rotateDisplay: Bool = false

    // Renderers
    private let monitorRenderer = MonitorRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(set: DisplaySet, brightness: Int, interval: Double, rotate: Bool) {
        self.currentSet = set
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate

        usbQueue.async { [weak self] in
            guard let self else { return }
            // Start background metrics collection (primes before returning)
            self.monitorRenderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    func stop() {
        running = false
        monitorRenderer.stopMetrics()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    func reconnect() {
        usbQueue.async { [weak self] in
            self?.connectAndRun()
        }
    }

    func updateSettings(set: DisplaySet, brightness: Int, interval: Double, rotate: Bool) {
        log("[Engine] Settings updated: set=\(set.rawValue), brightness=\(brightness), interval=\(interval), rotate=\(rotate)")
        self.currentSet = set
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate
    }

    // MARK: - Private (all on usbQueue)

    private func connectAndRun() {
        guard !running else { return }

        // Ensure metrics collection is running (may have been stopped on disconnect/sleep)
        monitorRenderer.startMetrics()

        // Close existing connection
        device?.close()
        device = nil
        frameCount = 0

        postStatus(connected: false, message: "Connecting...")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch USBError.deviceNotFound {
            postStatus(connected: false, message: "Device not found")
            return
        } catch USBError.deviceBusy {
            postStatus(connected: false, message: "Device busy (Chrome?)")
            return
        } catch {
            postStatus(connected: false, message: "Error: \(error)")
            return
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            device = dev
            postStatus(connected: true, deviceInfo: info,
                       message: "Connected (\(info.width)x\(info.height))")
            runFrameLoop(device: dev, info: info)
        } catch {
            dev.close()
            postStatus(connected: false, message: "Handshake failed")
        }
    }

    /// USB keep-alive period. The LCD blanks within seconds without frames, so the
    /// SEND cadence stays fixed at 0.5s regardless of the user's refresh setting.
    private static let sendInterval: TimeInterval = 0.5

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        running = true
        // Metrics already collecting in background via startMetrics()

        // Render cadence (user "Refresh" setting) is decoupled from send cadence:
        // render + JPEG-encode only every `interval`, and re-send the cached JPEG on
        // every 0.5s tick in between. Cuts CG/JPEG work without risking a blank LCD.
        var cachedJPEG: Data?
        var lastRender = DispatchTime(uptimeNanoseconds: 0)
        var lastSettings: (DisplaySet, Int, Bool)?

        var nextDeadline = DispatchTime.now()
        let sendNanos = UInt64(Self.sendInterval * 1_000_000_000)

        while running {
            // Schedule next frame deadline BEFORE work starts
            nextDeadline = nextDeadline + .nanoseconds(Int(sendNanos))

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let set = currentSet
                let bright = brightness
                let rotate = rotateDisplay
                let renderNanos = UInt64(max(interval, Self.sendInterval) * 1_000_000_000)

                // Re-render when the interval elapsed, nothing is cached yet, or a
                // visual setting changed (so brightness/rotate apply immediately).
                let now = DispatchTime.now()
                let settingsChanged = lastSettings.map { $0 != (set, bright, rotate) } ?? true
                let due = now.uptimeNanoseconds &- lastRender.uptimeNanoseconds >= renderNanos
                if cachedJPEG == nil || settingsChanged || due {
                    let fresh: Data?
                    switch set {
                    case .systemMonitor:
                        // The 180° turn is applied while drawing, so the encoder gets a
                        // frame already in device orientation (no second full-frame copy).
                        if let image = monitorRenderer.render(rotate180: !rotate) {
                            fresh = JPEGEncoder.encode(image, brightness: bright, rotate: true)
                        } else {
                            fresh = nil
                        }
                    }
                    if let fresh {
                        cachedJPEG = fresh
                        lastRender = now
                        lastSettings = (set, bright, rotate)
                    }
                }

                if let jpeg = cachedJPEG {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame, render every \(max(interval, Self.sendInterval))s, send every \(Self.sendInterval)s")
                        }
                        postStatus(connected: true, deviceInfo: nil,
                                   message: "Active")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        running = false
                        self.device?.close()
                        self.device = nil
                        postStatus(connected: false, message: "Disconnected (send error)")

                        log("[Engine] Will retry connection in 5s...")
                        Thread.sleep(forTimeInterval: 5)
                        connectAndRun()
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                Thread.sleep(forTimeInterval: Double(nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.running else { return }
                log("[Hotplug] Attempting reconnect...")
                self.monitorRenderer.startMetrics()
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.running = false
            self.monitorRenderer.stopMetrics()
            self.usbQueue.async { [weak self] in
                self?.device?.close()
                self?.device = nil
                self?.postStatus(connected: false, message: "Disconnected (unplugged)")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NSWorkspace.shared.notificationCenter

            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                self.usbQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.running = false
                    self.device?.close()
                    self.device = nil
                    log("[Wake] Attempting reconnect...")
                    self.connectAndRun()
                }
            }

            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.running {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    self.usbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, !self.running else { return }
                        self.connectAndRun()
                    }
                }
            }
        }
    }

    private func postStatus(
        connected: Bool, deviceInfo: DeviceInfo? = nil, message: String
    ) {
        let status = EngineStatus(
            connected: connected,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize)
        statusCallback(status)
    }
}
