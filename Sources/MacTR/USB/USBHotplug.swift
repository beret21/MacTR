// USBHotplug.swift — IOKit notification-based USB connect/disconnect detection
//
// Watches for Thermalright LCD device attach/detach events using IOKit notifications.
// Does NOT use libusb hotplug (limited on macOS). Instead uses IOServiceMatching
// with kIOFirstMatchNotification and kIOTerminatedNotification.
//
// Usage:
//   let hotplug = USBHotplug()
//   hotplug.onConnect = { ... }
//   hotplug.onDisconnect = { ... }
//   hotplug.start()

import Foundation
import IOKit
import IOKit.usb

final class USBHotplug: @unchecked Sendable {

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private let queue = DispatchQueue(label: "com.thermalvision.hotplug")

    // VID/PID pairs to watch
    private let devices: [(UInt16, UInt16)] = [
        (0x0416, 0x5408),  // LY
        (0x0416, 0x5409),  // LY1
    ]

    func start() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }

        IONotificationPortSetDispatchQueue(notifyPort, queue)

        for (vid, pid) in devices {
            let matching = createMatchingDict(vid: vid, pid: pid)

            // Watch for device added
            if let matchCopy = matching.map({ NSDictionary(dictionary: $0 as NSDictionary) as CFDictionary }) {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                IOServiceAddMatchingNotification(
                    notifyPort,
                    kIOFirstMatchNotification,
                    matchCopy,
                    deviceAdded,
                    selfPtr,
                    &addedIterator)
                // Drain existing matches
                drainIterator(addedIterator)
            }

            // Watch for device removed
            if let matchCopy = matching.map({ NSDictionary(dictionary: $0 as NSDictionary) as CFDictionary }) {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                IOServiceAddMatchingNotification(
                    notifyPort,
                    kIOTerminatedNotification,
                    matchCopy,
                    deviceRemoved,
                    selfPtr,
                    &removedIterator)
                // Drain existing matches
                drainIterator(removedIterator)
            }
        }

        print("[Hotplug] Watching for device connect/disconnect")
    }

    func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
    }

    /// Check if device is currently present (one-shot check)
    func isDevicePresent() -> Bool {
        for (vid, pid) in devices {
            guard let matching = createMatchingDict(vid: vid, pid: pid) else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            if result == KERN_SUCCESS {
                let service = IOIteratorNext(iterator)
                IOObjectRelease(iterator)
                if service != 0 {
                    IOObjectRelease(service)
                    return true
                }
            }
        }
        return false
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func createMatchingDict(vid: UInt16, pid: UInt16) -> CFMutableDictionary? {
        guard let dict = IOServiceMatching(kIOUSBDeviceClassName) else { return nil }
        let mutableDict = dict as NSMutableDictionary
        mutableDict[kUSBVendorID] = vid
        mutableDict[kUSBProductID] = pid
        return mutableDict
    }

    private func drainIterator(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

// MARK: - C callbacks

private func deviceAdded(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let hotplug = Unmanaged<USBHotplug>.fromOpaque(refcon!).takeUnretainedValue()
    // Drain iterator (required for notifications to keep firing)
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
    print("[Hotplug] Device connected")
    hotplug.onConnect?()
}

private func deviceRemoved(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let hotplug = Unmanaged<USBHotplug>.fromOpaque(refcon!).takeUnretainedValue()
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
    print("[Hotplug] Device disconnected")
    hotplug.onDisconnect?()
}
