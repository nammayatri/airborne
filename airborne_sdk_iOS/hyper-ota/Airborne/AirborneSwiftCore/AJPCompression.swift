/*
 * Copyright 2025 Juspay Technologies
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

import Foundation
import Compression

/// Transparent ZIP unwrapping for OTA payloads.
///
/// The uploader (catalyst ota push) may ship the bundle as raw bytes (JS
/// source or Hermes bytecode) or wrapped in a single-entry ZIP for smaller
/// transfer size. The SDK detects the wrapping by magic bytes and unwraps
/// before persisting. JS-vs-HBC detection is handled inside the Hermes VM
/// at load time, so this layer only concerns itself with ZIP.
public enum AJPCompression {

    public enum Error: Swift.Error, CustomStringConvertible {
        case malformedZip(String)
        case unsupportedMethod(UInt16)
        case deflateFailed

        public var description: String {
            switch self {
            case .malformedZip(let reason): return "malformed zip: \(reason)"
            case .unsupportedMethod(let m): return "unsupported zip compression method: \(m)"
            case .deflateFailed: return "DEFLATE inflation failed"
            }
        }
    }

    /// Returns the decompressed payload if `data` is a single-entry ZIP,
    /// otherwise returns `data` unchanged.
    public static func maybeDecompressZip(_ data: Data) throws -> Data {
        guard looksLikeZip(data) else { return data }
        return try extractSingleEntryZip(data)
    }

    private static func looksLikeZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // PK\x03\x04 — local file header signature of a standard ZIP.
        return data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }

    // The reader intentionally walks the central directory rather than the
    // first local file header: streaming zip writers (including Go's
    // archive/zip in its default mode) emit data descriptors with sizes of 0
    // in the local header, so the central directory is the only reliable
    // source for compressed/uncompressed sizes.
    private static func extractSingleEntryZip(_ data: Data) throws -> Data {
        let eocdOffset = try findEOCD(in: data)
        guard eocdOffset + 22 <= data.count else {
            throw Error.malformedZip("EOCD truncated")
        }
        let cdOffset = Int(data.readUInt32LE(at: eocdOffset + 16))

        guard cdOffset + 46 <= data.count else {
            throw Error.malformedZip("central directory truncated")
        }
        let cdSig = data.readUInt32LE(at: cdOffset)
        guard cdSig == 0x02014b50 else {
            throw Error.malformedZip("central directory signature mismatch")
        }
        let method = data.readUInt16LE(at: cdOffset + 10)
        let compressedSize = Int(data.readUInt32LE(at: cdOffset + 20))
        let uncompressedSize = Int(data.readUInt32LE(at: cdOffset + 24))
        let localHeaderOffset = Int(data.readUInt32LE(at: cdOffset + 42))

        guard localHeaderOffset + 30 <= data.count else {
            throw Error.malformedZip("local header truncated")
        }
        let localFilenameLen = Int(data.readUInt16LE(at: localHeaderOffset + 26))
        let localExtraLen = Int(data.readUInt16LE(at: localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + localFilenameLen + localExtraLen

        guard dataStart + compressedSize <= data.count else {
            throw Error.malformedZip("entry data truncated")
        }
        let compressed = data.subdata(in: dataStart..<(dataStart + compressedSize))

        switch method {
        case 0:  // STORED — no compression
            return compressed
        case 8:  // DEFLATE
            return try inflateDeflate(compressed, expectedSize: uncompressedSize)
        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private static func findEOCD(in data: Data) throws -> Int {
        // End of Central Directory record: 0x06054b50 little-endian.
        // Always near the end of the file; scan backward for speed.
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= sig.count else {
            throw Error.malformedZip("file too short for EOCD")
        }
        var i = data.count - sig.count
        while i >= 0 {
            if data[i] == sig[0] &&
               data[i + 1] == sig[1] &&
               data[i + 2] == sig[2] &&
               data[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        throw Error.malformedZip("EOCD signature not found")
    }

    // Apple's Compression framework: COMPRESSION_ZLIB consumes raw DEFLATE
    // (what zip entries store), not zlib-wrapped DEFLATE — exactly what we
    // want here.
    private static func inflateDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        let capacity = max(expectedSize, 64 * 1024)
        let dest = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dest.deallocate() }

        let decoded: Int = data.withUnsafeBytes { raw in
            guard let srcBase = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                dest, capacity,
                srcBase, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        if decoded == 0 {
            throw Error.deflateFailed
        }
        return Data(bytes: dest, count: decoded)
    }
}

// MARK: - Little-endian Data readers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        return UInt16(self[offset]) |
               (UInt16(self[offset + 1]) << 8)
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        return UInt32(self[offset]) |
               (UInt32(self[offset + 1]) << 8) |
               (UInt32(self[offset + 2]) << 16) |
               (UInt32(self[offset + 3]) << 24)
    }
}
