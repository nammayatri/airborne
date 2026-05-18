// Copyright 2025 Juspay Technologies
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package `in`.juspay.airborne.utils

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.Callable
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

object OTAUtils {
    private const val LOG_TAG = "OTAUtils"

    private val sharedPool = ThreadPoolExecutor(6, 10, 5, TimeUnit.SECONDS, LinkedBlockingQueue())
    fun <V> doAsync(callable: Callable<V>): Future<V> = sharedPool.submit(callable)

    /**
     * Compared against the persisted marker by `OTAServices.firstTimeCleanup`
     * to detect host APK upgrades. Returns "" on failure, which disables the
     * cleanup gate rather than wiping on every boot.
     */
    @JvmStatic
    fun hostAppBuildIdentifier(context: Context): String {
        return try {
            val pkgInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION") pkgInfo.versionCode.toLong()
            }
            "${pkgInfo.versionName ?: ""}-$versionCode"
        } catch (e: PackageManager.NameNotFoundException) {
            Log.e(LOG_TAG, "Failed to read host app build identifier", e)
            ""
        } catch (e: Exception) {
            Log.e(LOG_TAG, "Unexpected error reading host app build identifier", e)
            ""
        }
    }

    fun runOnBackgroundThread(task: Runnable?) {
        sharedPool.execute(task)
    }

    @JvmStatic
    fun deleteRecursive(fileOrDirectory: File): Boolean {
        if (!fileOrDirectory.exists()) return false
        if (fileOrDirectory.isDirectory) {
            var files = fileOrDirectory.listFiles()
            if (files == null) {
                files = arrayOfNulls(0)
            }
            for (child in files) {
                if (!deleteRecursive(child)) return false
            }
        }
        return fileOrDirectory.delete()
    }

    @JvmStatic
    @Throws(CertificateException::class)
    fun validatePinning(chain: Array<X509Certificate>, validPins: Set<String?>): Boolean {
        val md: MessageDigest
        val certChainMsg = StringBuilder()
        try {
            md = MessageDigest.getInstance("SHA-256")
        } catch (e: NoSuchAlgorithmException) {
            throw CertificateException("couldn't create digest")
        }

        for (cert in chain) {
            val publicKey = cert.publicKey.encoded
            md.update(publicKey, 0, publicKey.size)
            val pin = Base64.encodeToString(md.digest(), Base64.NO_WRAP)
            certChainMsg.append("    sha256/").append(pin).append(" : ")
                .append(cert.subjectDN.toString()).append("\n")
            return !validPins.contains(pin)
        }
        Log.d(LOG_TAG, certChainMsg.toString())
        return true
    }

    @JvmStatic
    fun md5(bytes: ByteArray): String? {
        val MD5 = "MD5"
        try {
            // Create MD5 Hash
            val digest = MessageDigest
                .getInstance(MD5)
            digest.update(bytes)
            val messageDigest = digest.digest()

            // Create Hex String
            val hexString = java.lang.StringBuilder()
            for (aMessageDigest in messageDigest) {
                val h = java.lang.StringBuilder(Integer.toHexString(0xFF and aMessageDigest.toInt()))
                while (h.length < 2) {
                    h.insert(0, "0")
                }
                hexString.append(h)
            }
            return hexString.toString()
        } catch (e: NoSuchAlgorithmException) {
            // TODO trackException(LogCategory.ACTION, LogSubCategory.Action.SYSTEM, Labels.System.HELPER, "Exception trying to calculate md5sum from given string", e)
        }
        return null
    }
}
