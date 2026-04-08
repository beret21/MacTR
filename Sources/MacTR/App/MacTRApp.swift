// MacTRApp.swift — macOS menu bar app
//
// Uses NSStatusItem directly (not SwiftUI MenuBarExtra) for reliable
// menu bar icon that never disappears regardless of USB state.
//
// CLI mode: --cli flag for headless operation.

import AppKit
import Sparkle
import SwiftUI

/// Flush stdout after print (Swift buffers when piped)
func log(_ message: String) {
    print(message)
    fflush(stdout)
}

// MARK: - App Entry Point

@main
struct MacTREntry {
    static func main() {
        // CLI mode
        if CommandLine.arguments.contains("--cli") {
            runCLI()
            return
        }

        // Snapshot mode: render one frame and save as PNG
        // Usage: --snapshot path.png [--cores N]
        if CommandLine.arguments.contains("--snapshot") {
            let renderer = MonitorRenderer()
            let simCores = parseFlag(CommandLine.arguments, flag: "--cores")

            // Prime metrics collection (required for real data render)
            renderer.startMetrics()
            Thread.sleep(forTimeInterval: 0.5)
            for _ in 0..<30 { _ = renderer.render(); Thread.sleep(forTimeInterval: 0.1) }

            let image: CGImage?
            if let cores = simCores {
                log("[Snapshot] Simulating \(cores) cores")
                image = renderer.renderSimulated(coreCount: cores)
            } else {
                image = renderer.render()
            }

            if let image {
                let url = URL(fileURLWithPath: CommandLine.arguments.last == "--snapshot"
                    ? "snapshot.png" : CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--snapshot")! + 1])
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                    log("[Snapshot] Saved to \(url.path)")
                }
            }
            return
        }

        // GUI mode — NSApplication with StatusBar
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // No dock icon
        let delegate = StatusBarController()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var menu: NSMenu!

    // Sparkle auto-updater
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var versionMenuItem: NSMenuItem!
    private var reconnectItem: NSMenuItem!
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[*] MacTR starting...")

        // Create status bar item — this NEVER gets removed
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        // Build menu
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Watch for device state changes — close menu so it refreshes
        // Update icon immediately on device state change
        NotificationCenter.default.addObserver(
            forName: .deviceStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
            self?.updateMenuItems()
        }

        // Start engine
        appState.start()

        // Timer to refresh menu + icon
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateMenuItems()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        appState.stop()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()
        updateMenuItems()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = makeIcon(disconnected: !appState.isConnected)
    }

    /// Draw menu bar icon manually. Connected = white display. Disconnected = display + red badge.
    private func makeIcon(disconnected: Bool) -> NSImage {
        let w: CGFloat = disconnected ? 22 : 18
        let h: CGFloat = 16

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let menuBarColor: NSColor = .labelColor  // adapts to dark/light mode

            // Draw monitor shape
            let screenRect = NSRect(x: 0, y: 4, width: 18, height: 11)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2, yRadius: 2)
            menuBarColor.setStroke()
            screenPath.lineWidth = 1.5
            screenPath.stroke()

            // Stand
            let standTop = NSPoint(x: 9, y: 4)
            let standBot = NSPoint(x: 9, y: 1.5)
            let stand = NSBezierPath()
            stand.move(to: standTop)
            stand.line(to: standBot)
            stand.lineWidth = 1.5
            menuBarColor.setStroke()
            stand.stroke()

            // Base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 5, y: 1.5))
            basePath.line(to: NSPoint(x: 13, y: 1.5))
            basePath.lineWidth = 1.5
            basePath.stroke()

            // Red badge (only when disconnected)
            if disconnected {
                let badgeD: CGFloat = 9
                let badgeRect = NSRect(
                    x: rect.width - badgeD + 0.5,
                    y: rect.height - badgeD + 0.5,
                    width: badgeD, height: badgeD)

                // Red circle
                NSColor.red.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()

                // White "!"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .black),
                    .foregroundColor: NSColor.white,
                ]
                let mark = "!" as NSString
                let markSize = mark.size(withAttributes: attrs)
                mark.draw(at: NSPoint(
                    x: badgeRect.midX - markSize.width / 2,
                    y: badgeRect.midY - markSize.height / 2),
                    withAttributes: attrs)
            }

            return true
        }

        // Template only when connected (so it adapts to dark/light mode)
        // Non-template when disconnected (to keep red badge color)
        image.isTemplate = !disconnected
        return image
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()

        // App title + version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
        versionMenuItem = NSMenuItem(title: "MacTR v\(version)", action: nil, keyEquivalent: "")
        versionMenuItem.isEnabled = false
        menu.addItem(versionMenuItem)

        // Status
        statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // Reconnect
        reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Check for Updates
        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "u")
        checkUpdatesItem.target = updaterController
        menu.addItem(checkUpdatesItem)

        // About
        let aboutItem = NSMenuItem(title: "About MacTR", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit MacTR", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuItems()
    }

    private func updateMenuItems() {
        // Status
        let dot = appState.isConnected ? "🟢" : "🔴"
        statusMenuItem.title = "\(dot) \(appState.statusMessage)"

        // Reconnect visibility
        reconnectItem.isHidden = appState.isConnected
    }

    // MARK: - Actions

    @objc private func reconnect() {
        appState.connect()
    }

    @objc private func openSettings() {
        // Open settings window
        let settingsView = SettingsView(state: appState)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacTR Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 350))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        let alert = NSAlert()
        alert.messageText = "MacTR"
        alert.informativeText = """
            Version \(version) (Build \(build))

            Mac + Thermalright
            Native macOS driver for Thermalright
            Trofeo Vision 9.16 LCD display.

            Built with Swift + libusb
            github.com/beret21/MacTR
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        appState.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - CLI Mode

private func runCLI() {
    let args = CommandLine.arguments
    let isTest = args.contains("--test")
    let brightness = parseFlag(args, flag: "-b") ?? 5
    let rotate = args.contains("--rotate")

    log("[*] MacTR CLI — \(isTest ? "USB Test" : "System Monitor")")
    log("[*] Brightness: level \(brightness) (\(Brightness.factor(for: brightness))x), Rotate: \(rotate)")
    log("[*] Searching for Thermalright LCD...")

    let device = USBDevice()

    do {
        try device.open()
    } catch {
        log("[ERROR] \(error)")
        return
    }

    defer { device.close() }

    let info: DeviceInfo
    do {
        info = try LYProtocol.handshake(device: device)
    } catch {
        log("[ERROR] Handshake failed: \(error)")
        return
    }

    if isTest {
        guard let jpeg = makeTestJPEG(width: info.width, height: info.height) else {
            log("[ERROR] Failed to create test image")
            return
        }
        log("[*] JPEG size: \(jpeg.count) bytes")
        cliFrameLoop(device: device, staticJPEG: jpeg)
    } else {
        let renderer = MonitorRenderer()
        renderer.startMetrics()
        Thread.sleep(forTimeInterval: 0.3)

        log("[*] Sending frames (press Ctrl+C to stop)...")
        signal(SIGINT, SIG_DFL)

        var count = 0
        while true {
            guard let image = renderer.render(),
                  let jpeg = JPEGEncoder.encode(image, brightness: brightness, rotate: rotate)
            else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            do {
                try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                count += 1
                if count == 1 {
                    log("[OK] Monitor active! ~\(jpeg.count / 1024)KB/frame (Ctrl+C to stop)")
                }
            } catch {
                log("[ERROR] Frame send failed: \(error)")
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

private func cliFrameLoop(device: USBDevice, staticJPEG: Data) {
    log("[*] Sending frames (press Ctrl+C to stop)...")
    signal(SIGINT, SIG_DFL)
    var count = 0
    while true {
        do {
            try LYProtocol.sendFrame(device: device, jpegData: staticJPEG)
            count += 1
            if count == 1 { log("[OK] Display active! Looping...") }
        } catch {
            log("[ERROR] Frame send failed: \(error)")
            break
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

private func parseFlag(_ args: [String], flag: String) -> Int? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

// MARK: - Test Image

func makeTestJPEG(width: Int, height: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let colors = [
        CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1),
        CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(height)),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    let text = "MacTR — Swift USB Test" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 48, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    let x = (CGFloat(width) - textSize.width) / 2

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    text.draw(at: NSPoint(x: x, y: CGFloat(height) / 2 - textSize.height / 2), withAttributes: attrs)

    let sub = "macOS 26 \u{2022} Swift 6.3 \u{2022} libusb" as NSString
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24),
        .foregroundColor: NSColor(white: 0.6, alpha: 1),
    ]
    let subSize = sub.size(withAttributes: subAttrs)
    sub.draw(at: NSPoint(x: (CGFloat(width) - subSize.width) / 2,
                         y: CGFloat(height) / 2 + textSize.height / 2 + 10),
             withAttributes: subAttrs)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return JPEGEncoder.encode(image)
}
