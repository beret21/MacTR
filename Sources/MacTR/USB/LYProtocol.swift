// LYProtocol.swift — LY / LY1 display protocol for the Thermalright Trofeo Vision LCD
//
// Two operations on an opened USBDevice:
//   • handshake  — identify the panel (PM / SUB / FBL) and derive its resolution
//   • sendFrame  — split a JPEG into 512-byte chunks and stream them over bulk OUT
//
// Implemented from DISPLAY_PROTOCOL.md (protocol specification). Protocol facts
// originate from the reverse engineering by thermalright-trcc-linux (GPL-3.0);
// no code from that project is used.

import Foundation

// MARK: - Device description

/// What the handshake learned about the connected panel.
struct DeviceInfo: Sendable {
    let pm: Int
    let sub: Int
    let fbl: Int
    let width: Int
    let height: Int
    let usesJPEG: Bool
    let needsRotation: Bool
    let pid: UInt16

    init(pm: Int, sub: Int, fbl: Int, width: Int, height: Int,
         usesJPEG: Bool, needsRotation: Bool, pid: UInt16) {
        self.pm = pm
        self.sub = sub
        self.fbl = fbl
        self.width = width
        self.height = height
        self.usesJPEG = usesJPEG
        self.needsRotation = needsRotation
        self.pid = pid
    }
}

// MARK: - Errors

enum LYError: Error, CustomStringConvertible {
    /// The device answered the handshake with an unexpected or "not ready" reply.
    case handshakeFailed
    /// The JPEG payload exceeds the maximum the panel accepts (bytes given).
    case frameTooLarge(Int)
    /// A bulk write reported zero bytes transferred, so the frame cannot progress.
    case writeStalled(offset: Int)

    var description: String {
        switch self {
        case .handshakeFailed:
            "Handshake failed (unexpected or not-ready response)"
        case .frameTooLarge(let size):
            "Frame too large: \(size) bytes (limit \(LYProtocol.maxFrameBytes))"
        case .writeStalled(let offset):
            "Bulk write stalled at byte offset \(offset)"
        }
    }
}

// MARK: - Protocol

enum LYProtocol {

    // Spec §2.1
    private static let pidLY: UInt16 = 0x5408
    private static let pidLY1: UInt16 = 0x5409

    /// Largest JPEG payload sendFrame will accept.
    static let maxFrameBytes = 650_000

    // Spec §3 — handshake
    private static let helloLength = 2048
    private static let replyLength = 512
    private static let replyMinimumLength = 37
    private static let handshakeTimeoutMs: UInt32 = 1000
    private static let maxHandshakeAttempts = 5
    private static let notReadyDelay: TimeInterval = 0.2

    // Spec §4 — frame transfer
    private static let chunkSize = 512
    private static let chunkHeaderSize = 16
    private static let chunkPayloadSize = chunkSize - chunkHeaderSize   // 496
    private static let writeBlockSize = 4096
    private static let writeTimeoutMs: UInt32 = 5000
    private static let ackLength = 512
    private static let ackTimeoutMs: UInt32 = 1000

    // MARK: Handshake

    /// Performs the identification exchange and returns the panel description.
    /// Retries while the device reports "not ready" (spec §3.2).
    static func handshake(device: USBDevice) throws -> DeviceInfo {
        let hello = makeHelloPacket()

        var reply = Data()
        var attempt = 0
        while true {
            attempt += 1
            _ = try device.bulkWrite(hello, timeout: handshakeTimeoutMs)
            reply = try device.bulkRead(size: replyLength, timeout: handshakeTimeoutMs)

            let bytes = [UInt8](reply)
            if isNotReady(bytes) {
                guard attempt < maxHandshakeAttempts else {
                    print("[LY] Device still not ready after \(attempt) attempts")
                    throw LYError.handshakeFailed
                }
                print("[LY] Device not ready (attempt \(attempt)/\(maxHandshakeAttempts)), retrying")
                Thread.sleep(forTimeInterval: notReadyDelay)
                continue
            }
            break
        }

        let bytes = [UInt8](reply)
        guard bytes.count >= replyMinimumLength,
              bytes[0] == 0x03, bytes[1] == 0xFF, bytes[8] == 0x01
        else {
            print("[LY] Unexpected handshake reply (\(bytes.count) bytes)")
            throw LYError.handshakeFailed
        }

        let pid = device.pid
        let (pm, sub) = panelModel(from: bytes, pid: pid)
        let fbl = fblCode(forPM: pm)
        let (width, height) = resolution(fbl: fbl, pm: pm)

        print("[LY] Handshake OK: PM=\(pm) SUB=\(sub) FBL=\(fbl) "
              + "\(width)x\(height) PID=\(String(format: "0x%04X", pid))")

        return DeviceInfo(pm: pm, sub: sub, fbl: fbl, width: width, height: height,
                          usesJPEG: true, needsRotation: true, pid: pid)
    }

    /// 2048 bytes: fixed 16-byte preamble followed by zeros (spec §3.1).
    private static func makeHelloPacket() -> Data {
        var packet = Data(count: helloLength)
        packet[0] = 0x02
        packet[1] = 0xFF
        packet[8] = 0x01
        return packet
    }

    /// Header bytes are valid but the status byte says the panel is still booting.
    private static func isNotReady(_ bytes: [UInt8]) -> Bool {
        bytes.count > 8 && bytes[0] == 0x03 && bytes[1] == 0xFF && bytes[8] == 0x02
    }

    /// PM / SUB extraction per model (spec §3.3).
    private static func panelModel(from bytes: [UInt8], pid: UInt16) -> (pm: Int, sub: Int) {
        if pid == pidLY1 {
            return (50 + Int(bytes[36]), Int(bytes[22]))
        }
        // LY: a raw value of 3 or less is treated as 1.
        let raw = Int(bytes[20])
        let adjusted = raw <= 3 ? 1 : raw
        return (64 + adjusted, Int(bytes[22]) + 1)
    }

    /// PM → FBL mapping (spec §3.4 step 1).
    private static func fblCode(forPM pm: Int) -> Int {
        switch pm {
        case 63, 64: 114
        case 65, 66, 68, 69: 192
        default: pm
        }
    }

    /// FBL (+ PM for the 192 family) → panel resolution (spec §3.4 step 2).
    private static func resolution(fbl: Int, pm: Int) -> (width: Int, height: Int) {
        switch fbl {
        case 192:
            switch pm {
            case 68: (1280, 480)
            case 69: (1920, 440)
            default: (1920, 480)
            }
        case 114: (1600, 720)
        case 128: (1280, 480)
        default: (1920, 462)
        }
    }

    // MARK: Frame transfer

    /// Streams one JPEG frame to the panel and waits for its acknowledgement.
    static func sendFrame(device: USBDevice, jpegData: Data) throws {
        guard jpegData.count <= maxFrameBytes else {
            throw LYError.frameTooLarge(jpegData.count)
        }

        let stream = buildChunkStream(jpeg: jpegData, isLY1: device.pid == pidLY1)

        // Write in 4096-byte blocks; advance only by what the device actually took.
        var offset = 0
        while offset < stream.count {
            let length = min(writeBlockSize, stream.count - offset)
            let block = stream.subdata(in: offset..<(offset + length))
            let sent = try device.bulkWrite(block, timeout: writeTimeoutMs)
            guard sent > 0 else { throw LYError.writeStalled(offset: offset) }
            offset += sent
        }

        // Acknowledgement content is not inspected; a failed read propagates.
        _ = try device.bulkRead(size: ackLength, timeout: ackTimeoutMs)
    }

    /// Lays out the 512-byte chunks (16-byte header + up to 496 bytes of JPEG each),
    /// then pads LY streams with zero chunks to a multiple of four (spec §4.1–4.3).
    private static func buildChunkStream(jpeg: Data, isLY1: Bool) -> Data {
        let total = jpeg.count
        // Always one extra chunk, even when the size divides evenly (last chunk may be empty).
        let chunkCount = total / chunkPayloadSize + 1
        let command: UInt8 = isLY1 ? 0x02 : 0x01

        var paddedCount = chunkCount
        if !isLY1 {
            let remainder = paddedCount % 4
            if remainder != 0 { paddedCount += 4 - remainder }
        }

        var stream = Data(count: paddedCount * chunkSize)
        let source = [UInt8](jpeg)

        stream.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for index in 0..<chunkCount {
                let start = index * chunkPayloadSize
                let length = min(chunkPayloadSize, total - start)
                let base = index * chunkSize

                out[base + 0] = 0x01
                out[base + 1] = 0xFF
                putLittleEndian(UInt32(total), into: out, at: base + 2)
                putLittleEndian(UInt16(length), into: out, at: base + 6)
                out[base + 8] = command
                putLittleEndian(UInt16(chunkCount), into: out, at: base + 9)
                putLittleEndian(UInt16(index), into: out, at: base + 11)
                // bytes 13..15 stay zero

                for i in 0..<length {
                    out[base + chunkHeaderSize + i] = source[start + i]
                }
            }
        }
        return stream
    }

    private static func putLittleEndian<T: FixedWidthInteger>(
        _ value: T, into buffer: UnsafeMutableBufferPointer<UInt8>, at position: Int
    ) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[position + i] = byte
            }
        }
    }
}
