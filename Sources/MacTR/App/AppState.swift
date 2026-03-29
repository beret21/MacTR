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
    var refreshInterval: Double = 0.5
    var rotateDisplay: Bool = false

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
    private var interval: Double = 0.5
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
            self?.setupHotplug()
            self?.connectAndRun()
        }
    }

    func stop() {
        running = false
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

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        running = true

        // Prime CPU metrics
        _ = monitorRenderer.render()
        Thread.sleep(forTimeInterval: 0.3)

        while running {
            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let set = currentSet
                let bright = brightness
                let rotate = rotateDisplay

                let jpeg: Data?

                switch set {
                case .systemMonitor:
                    if let image = monitorRenderer.render() {
                        jpeg = JPEGEncoder.encode(image, brightness: bright, rotate: rotate)
                    } else {
                        jpeg = nil
                    }
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
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
                        if !running {
                            connectAndRun()
                        }
                        return
                    }
                }
            }  // autoreleasepool

            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.running else { return }
                log("[Hotplug] Attempting reconnect...")
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.running = false
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
