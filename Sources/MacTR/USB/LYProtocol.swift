// LYProtocol.swift — LY Bulk protocol for Thermalright LCD
//
// Implements handshake and chunked JPEG frame transfer.
// Direct port from Python trcc_mac.py.
//
// Protocol reference:
//   https://github.com/Lexonight1/thermalright-trcc-linux
//   src/trcc/adapters/device/ly.py

import Foundation

// MARK: - Device Info

struct DeviceInfo: Sendable {
    let pm: Int
    let sub: Int
    let fbl: Int
    let width: Int
    let height: Int
    let usesJPEG: Bool
    let needsRotation: Bool
    let pid: UInt16
}

// MARK: - Constants

private let handshakeHeader: [UInt8] = [
    0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]

private let chunkSize = 512
private let chunkHeaderSize = 16
private let chunkDataSize = 496  // 512 - 16
private let usbWriteSize = 4096
private let maxJPEGSize = 650_000

// PM → FBL overrides
private let pmToFBL: [Int: Int] = [
    65: 192, 66: 192, 68: 192, 69: 192,
    64: 114, 63: 114,
]

// FBL → (width, height, jpeg, rotate)
private let fblProfiles: [Int: (Int, Int, Bool, Bool)] = [
    192: (1920, 480, true, true),  // 제품 사양 기준 (프로토콜 기본값 462는 무시)
    114: (1600, 720, true, true),
    128: (1280, 480, true, true),
]

// FBL 192: PM-based resolution disambiguation
private let fbl192ByPM: [Int: (Int, Int)] = [
    68: (1280, 480),
    69: (1920, 440),
]

// MARK: - LYProtocol

enum LYProtocol {

    /// Perform USB handshake with the LCD device.
    /// Sends 2048-byte init packet, reads 512-byte response, extracts device info.
    static func handshake(device: USBDevice) throws -> DeviceInfo {
        // Build 2048-byte handshake payload
        var payload = Data(count: 2048)
        for (i, byte) in handshakeHeader.enumerated() {
            payload[i] = byte
        }

        // Send handshake
        _ = try device.bulkWrite(payload, timeout: 1000)
        print("[LY] Handshake sent (2048 bytes)")

        // Read response
        let resp = try device.bulkRead(size: 512, timeout: 1000)
        print("[LY] Response: \(resp.count) bytes")
        print("[LY] Hex (first 48): \(resp.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Validate
        guard resp.count >= 37,
              resp[0] == 3,
              resp[1] == 0xFF,
              resp[8] == 1
        else {
            let b0 = resp.count > 0 ? String(format: "%02x", resp[0]) : "??"
            let b1 = resp.count > 1 ? String(format: "%02x", resp[1]) : "??"
            let b8 = resp.count > 8 ? String(format: "%02x", resp[8]) : "??"
            print("[ERROR] Handshake validation failed: [0]=\(b0) [1]=\(b1) [8]=\(b8)")
            throw LYError.handshakeFailed
        }

        // Extract PM and SUB
        let pm: Int
        let sub: Int
        let pid = device.pid

        if pid == 0x5408 {  // LY type
            var rawPM = Int(resp[20])
            if rawPM <= 3 { rawPM = 1 }
            pm = 64 + rawPM
            sub = resp.count > 22 ? Int(resp[22]) + 1 : 0
        } else {  // LY1 type
            pm = 50 + Int(resp[36])
            sub = resp.count > 22 ? Int(resp[22]) : 0
        }

        // PM → FBL → resolution
        let fbl = pmToFBL[pm] ?? pm
        let width: Int
        let height: Int
        let usesJPEG: Bool
        let needsRotation: Bool

        if let profile = fblProfiles[fbl] {
            var w = profile.0
            var h = profile.1
            usesJPEG = profile.2
            needsRotation = profile.3
            // PM-based disambiguation for FBL 192
            if fbl == 192, let override = fbl192ByPM[pm] {
                w = override.0
                h = override.1
            }
            width = w
            height = h
        } else {
            width = 1920
            height = 462
            usesJPEG = true
            needsRotation = true
        }

        let info = DeviceInfo(
            pm: pm, sub: sub, fbl: fbl,
            width: width, height: height,
            usesJPEG: usesJPEG, needsRotation: needsRotation,
            pid: pid)

        print("[OK] Handshake successful!")
        print("     PM=\(pm), SUB=\(sub), FBL=\(fbl)")
        print("     Resolution: \(width)x\(height)")
        print("     JPEG mode: \(usesJPEG), Rotate: \(needsRotation)")

        return info
    }

    /// Send one JPEG frame using LY chunked bulk protocol.
    static func sendFrame(device: USBDevice, jpegData: Data) throws {
        let pid = device.pid
        let chunkCmd: UInt8 = (pid == 0x5408) ? 0x01 : 0x02

        let totalSize = jpegData.count
        let numChunks = totalSize / chunkDataSize + 1
        let lastChunkData = totalSize % chunkDataSize

        // Build all 512-byte chunks
        var chunks = Data(count: numChunks * chunkSize)

        for i in 0..<numChunks {
            let offset = i * chunkSize
            let isLast = (i == numChunks - 1)
            let dataLen = isLast ? lastChunkData : chunkDataSize

            // 16-byte header (little-endian)
            chunks[offset] = 0x01
            chunks[offset + 1] = 0xFF

            // Total payload size (LE32) at offset+2
            chunks.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: UInt32(totalSize).littleEndian,
                               toByteOffset: offset + 2, as: UInt32.self)
                // This chunk's data length (LE16) at offset+6
                ptr.storeBytes(of: UInt16(dataLen).littleEndian,
                               toByteOffset: offset + 6, as: UInt16.self)
            }

            chunks[offset + 8] = chunkCmd

            // Total chunk count (LE16) at offset+9, chunk index (LE16) at offset+11
            chunks.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: UInt16(numChunks).littleEndian,
                               toByteOffset: offset + 9, as: UInt16.self)
                ptr.storeBytes(of: UInt16(i).littleEndian,
                               toByteOffset: offset + 11, as: UInt16.self)
            }

            // Padding bytes [13:16] are already zero

            // Copy payload
            let srcOffset = i * chunkDataSize
            let destOffset = offset + chunkHeaderSize
            if dataLen > 0 {
                chunks.replaceSubrange(
                    destOffset..<destOffset + dataLen,
                    with: jpegData[srcOffset..<srcOffset + dataLen])
            }
        }

        // Pad chunk count to multiple of 4 (LY type) or 1 (LY1)
        let padMultiple = (pid == 0x5408) ? 4 : 1
        var paddedChunks = numChunks
        let remainder = paddedChunks % padMultiple
        if remainder != 0 {
            paddedChunks += padMultiple - remainder
        }
        let totalBytes = paddedChunks * chunkSize

        // Extend with zeros if needed
        var sendBuf = chunks
        if totalBytes > chunks.count {
            sendBuf.append(Data(count: totalBytes - chunks.count))
        }

        // Send in 4096-byte batches
        var pos = 0
        while pos < totalBytes {
            let remaining = totalBytes - pos
            let writeSize: Int
            if remaining >= usbWriteSize {
                writeSize = usbWriteSize
            } else {
                writeSize = (pid == 0x5408) ? min(2048, remaining) : remaining
            }
            let slice = sendBuf[pos..<pos + writeSize]
            _ = try device.bulkWrite(Data(slice), timeout: 5000)
            pos += usbWriteSize
        }

        // Read ACK
        _ = try device.bulkRead(size: 512, timeout: 1000)
    }
}

// MARK: - LYError

enum LYError: Error, CustomStringConvertible {
    case handshakeFailed
    case frameTooLarge(Int)

    var description: String {
        switch self {
        case .handshakeFailed: "Handshake validation failed"
        case .frameTooLarge(let size): "JPEG frame too large: \(size) bytes (max \(maxJPEGSize))"
        }
    }
}
