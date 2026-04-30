/*
 * Copyright 2025 Juspay Technologies
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package `in`.juspay.airborne.ota

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.ZipInputStream

/**
 * Transparent compression handling for OTA payloads.
 *
 * The uploader (catalyst ota push) may ship the bundle as raw bytes (JS
 * source or Hermes bytecode) or wrapped in a single-entry ZIP for smaller
 * transfer size. The SDK detects the wrapping by magic bytes and unwraps
 * before persisting. JS-vs-HBC detection is handled inside the Hermes VM
 * at load time, so this layer only concerns itself with ZIP.
 */
internal object Compression {

    /**
     * Returns the decompressed payload if [input] is a single-entry ZIP
     * archive, otherwise returns [input] unchanged.
     *
     * Detection is by magic bytes (PK\x03\x04) at offset 0 — independent
     * of any file extension convention so the server-side file_path stays
     * stable across compressed and uncompressed uploads.
     */
    fun maybeDecompressZip(input: ByteArray): ByteArray {
        if (!looksLikeZip(input)) return input
        return decompressSingleEntryZip(input)
    }

    private fun looksLikeZip(bytes: ByteArray): Boolean {
        if (bytes.size < 4) return false
        // PK\x03\x04 — local file header signature of a standard ZIP.
        return bytes[0] == 0x50.toByte() &&
            bytes[1] == 0x4B.toByte() &&
            bytes[2] == 0x03.toByte() &&
            bytes[3] == 0x04.toByte()
    }

    private fun decompressSingleEntryZip(input: ByteArray): ByteArray {
        ZipInputStream(ByteArrayInputStream(input)).use { zis ->
            val entry = zis.nextEntry
                ?: throw IOException("Airborne: ZIP payload has no entries")
            val out = ByteArrayOutputStream(
                if (entry.size > 0) entry.size.toInt() else input.size * 3
            )
            zis.copyTo(out)
            return out.toByteArray()
        }
    }
}
