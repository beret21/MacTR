// USBDevice.swift — libusb wrapper for Thermalright LCD USB communication
//
// Wraps libusb C API for Swift. Handles device discovery, configuration,
// interface claiming, and bulk transfers.
//
// Usage:
//   let device = USBDevice()
//   try device.open()
//   let data = try device.bulkRead(size: 512, timeout: 1000)
//   try device.bulkWrite(data, timeout: 5000)
//   device.close()

import CLibUSB
import Foundation

// MARK: - Error

enum USBError: Error, CustomStringConvertible {
    case initFailed(Int32)
    case deviceNotFound
    case openFailed(Int32)
    case configurationFailed(Int32)
    case claimFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case deviceBusy

    var description: String {
        switch self {
        case .initFailed(let code): "libusb init failed (code \(code))"
        case .deviceNotFound: "Device not found (VID:0416 PID:5408/5409)"
        case .openFailed(let code): "Failed to open device (code \(code))"
        case .configurationFailed(let code): "Failed to set configuration (code \(code))"
        case .claimFailed(let code): "Failed to claim interface (code \(code))"
        case .writeFailed(let code): "Bulk write failed (code \(code))"
        case .readFailed(let code): "Bulk read failed (code \(code))"
        case .deviceBusy: "Device in use by another application (Chrome WebUSB?)"
        }
    }
}

// MARK: - Constants

private let VID: UInt16 = 0x0416
private let PID_LY: UInt16 = 0x5408
private let PID_LY1: UInt16 = 0x5409

// MARK: - USBDevice

final class USBDevice: @unchecked Sendable {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private(set) var pid: UInt16 = 0
    private(set) var epOut: UInt8 = 0x09
    private(set) var epIn: UInt8 = 0x81
    private(set) var interfaceNumber: Int32 = 0

    var isConnected: Bool { handle != nil }

    // MARK: - Lifecycle

    func open() throws {
        // Initialize libusb
        var ctx: OpaquePointer?
        let initResult = libusb_init(&ctx)
        guard initResult == LIBUSB_SUCCESS.rawValue else {
            throw USBError.initFailed(initResult)
        }
        context = ctx

        // Try PID_LY first, then PID_LY1
        for tryPID in [PID_LY, PID_LY1] {
            handle = libusb_open_device_with_vid_pid(context, VID, tryPID)
            if handle != nil {
                pid = tryPID
                break
            }
        }

        guard handle != nil else {
            libusb_exit(context)
            context = nil
            throw USBError.deviceNotFound
        }

        // Detach kernel driver (macOS: may return NOT_SUPPORTED, that's OK)
        for i: Int32 in 0..<4 {
            let active = libusb_kernel_driver_active(handle, i)
            if active == 1 {
                let detachResult = libusb_detach_kernel_driver(handle, i)
                if detachResult == LIBUSB_SUCCESS.rawValue {
                    print("[USB] Detached kernel driver from interface \(i)")
                }
                // NOT_SUPPORTED (-12) is expected on macOS — ignore
            }
        }

        // Set configuration
        let configResult = libusb_set_configuration(handle, 1)
        if configResult != LIBUSB_SUCCESS.rawValue
            && configResult != LIBUSB_ERROR_BUSY.rawValue
        {
            throw USBError.configurationFailed(configResult)
        }

        // Find vendor-specific interface and endpoints
        try findEndpoints()

        // Claim interface
        let claimResult = libusb_claim_interface(handle, interfaceNumber)
        if claimResult == LIBUSB_ERROR_BUSY.rawValue {
            close()
            throw USBError.deviceBusy
        }
        guard claimResult == LIBUSB_SUCCESS.rawValue else {
            close()
            throw USBError.claimFailed(claimResult)
        }

        print("[USB] Opened \(String(format: "%04x:%04x", VID, pid))"
              + "  EP_OUT=0x\(String(format: "%02x", epOut))"
              + "  EP_IN=0x\(String(format: "%02x", epIn))")
    }

    func close() {
        if let handle {
            libusb_release_interface(handle, interfaceNumber)
            libusb_close(handle)
        }
        handle = nil
        if let context {
            libusb_exit(context)
        }
        context = nil
    }

    deinit {
        close()
    }

    // MARK: - Transfers

    func bulkWrite(_ data: Data, timeout: UInt32 = 5000) throws -> Int {
        var transferred: Int32 = 0
        let result = data.withUnsafeBytes { ptr in
            let mutable = UnsafeMutablePointer(
                mutating: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
            return libusb_bulk_transfer(
                handle, epOut, mutable, Int32(data.count),
                &transferred, timeout)
        }
        guard result == LIBUSB_SUCCESS.rawValue else {
            throw USBError.writeFailed(result)
        }
        return Int(transferred)
    }

    func bulkRead(size: Int, timeout: UInt32 = 1000) throws -> Data {
        var buffer = Data(count: size)
        var transferred: Int32 = 0
        let result = buffer.withUnsafeMutableBytes { ptr in
            libusb_bulk_transfer(
                handle, epIn,
                ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                Int32(size), &transferred, timeout)
        }
        guard result == LIBUSB_SUCCESS.rawValue else {
            throw USBError.readFailed(result)
        }
        return buffer.prefix(Int(transferred))
    }

    // MARK: - Private

    private func findEndpoints() throws {
        guard let handle else { return }
        let dev = libusb_get_device(handle)

        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        libusb_get_active_config_descriptor(dev, &config)

        guard let config else {
            // Try setting configuration first
            libusb_set_configuration(handle, 1)
            var retry: UnsafeMutablePointer<libusb_config_descriptor>?
            libusb_get_active_config_descriptor(dev, &retry)
            guard let retry else { return }
            defer { libusb_free_config_descriptor(retry) }
            scanConfig(retry)
            return
        }
        defer { libusb_free_config_descriptor(config) }
        scanConfig(config)
    }

    private func scanConfig(
        _ config: UnsafeMutablePointer<libusb_config_descriptor>
    ) {
        let numInterfaces = Int(config.pointee.bNumInterfaces)
        for i in 0..<numInterfaces {
            let iface = config.pointee.interface.advanced(by: i)
            for j in 0..<Int(iface.pointee.num_altsetting) {
                let alt = iface.pointee.altsetting.advanced(by: j)
                // Look for vendor-specific interface (class 255)
                if alt.pointee.bInterfaceClass == 255 {
                    interfaceNumber = Int32(alt.pointee.bInterfaceNumber)
                    scanEndpoints(alt.pointee)
                    return
                }
            }
        }
        // Fallback: use first interface
        if numInterfaces > 0 {
            let alt = config.pointee.interface.pointee.altsetting.pointee
            interfaceNumber = Int32(alt.bInterfaceNumber)
            scanEndpoints(alt)
        }
    }

    private func scanEndpoints(_ alt: libusb_interface_descriptor) {
        for k in 0..<Int(alt.bNumEndpoints) {
            let ep = alt.endpoint.advanced(by: k)
            let addr = ep.pointee.bEndpointAddress
            let attr = ep.pointee.bmAttributes
            let isBulk = (attr & 0x03) == UInt8(LIBUSB_ENDPOINT_TRANSFER_TYPE_BULK.rawValue)
            if isBulk {
                if (addr & 0x80) == 0 {
                    epOut = addr  // OUT endpoint
                } else {
                    epIn = addr   // IN endpoint
                }
            }
        }
    }
}
