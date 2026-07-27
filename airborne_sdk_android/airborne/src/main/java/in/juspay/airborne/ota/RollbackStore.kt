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

package `in`.juspay.airborne.ota

import android.util.Log
import `in`.juspay.airborne.TrackerCallback
import `in`.juspay.airborne.constants.LogCategory
import `in`.juspay.airborne.constants.LogLevel
import `in`.juspay.airborne.constants.LogSubCategory
import `in`.juspay.airborne.ota.Constants.APP_DIR
import `in`.juspay.airborne.ota.Constants.CONFIG_FILE_NAME
import `in`.juspay.airborne.ota.Constants.INSTALL_MARKER_FILE_NAME
import `in`.juspay.airborne.ota.Constants.PACKAGE_DIR_NAME
import `in`.juspay.airborne.ota.Constants.PACKAGE_MANIFEST_FILE_NAME
import `in`.juspay.airborne.ota.Constants.PREV_DIR_NAME
import `in`.juspay.airborne.ota.Constants.RC_VERSION_FILE_NAME
import `in`.juspay.airborne.ota.Constants.RESTORE_STAGING_DIR_NAME
import `in`.juspay.airborne.ota.Constants.RESOURCES_FILE_NAME
import `in`.juspay.airborne.services.Workspace
import org.json.JSONObject
import java.io.File

internal enum class BootDecision { NORMAL, TRIAL, ROLLED_BACK }

internal class RollbackStore(
    private val workspace: Workspace,
    private val tracker: TrackerCallback
) {
    private val manifestFiles = listOf(
        PACKAGE_MANIFEST_FILE_NAME,
        INSTALL_MARKER_FILE_NAME,
        RC_VERSION_FILE_NAME,
        CONFIG_FILE_NAME,
        RESOURCES_FILE_NAME
    )

    fun trialVersion(): String = readKv(KEY_TRIAL_VERSION)

    fun safeVersion(): String = readKv(KEY_SAFE_VERSION)

    fun failedVersions(): Set<String> =
        readKv(KEY_FAILED).split(',').filter { it.isNotEmpty() }.toSet()

    fun isFailed(version: String): Boolean =
        version.isNotEmpty() && failedVersions().contains(version)

    fun isTrialUnconfirmed(loadedVersion: String?): Boolean {
        val trial = trialVersion()
        return trial.isNotEmpty() && trial == loadedVersion && trial != safeVersion()
    }

    fun snapshotActiveAsPrev() {
        if (trialVersion().isNotEmpty()) return
        if (readMarker().isEmpty()) return
        val activePkg = appFile(PACKAGE_DIR_NAME)
        if (!activePkg.exists()) return
        try {
            clearPrev()
            val prevPkg = prevFile(PACKAGE_DIR_NAME)
            prevPkg.parentFile?.mkdirs()
            val copied = activePkg.copyRecursively(prevPkg, overwrite = true)
            if (!copied) {
                clearPrev()
                track(LogLevel.ERROR, "ota_snapshot_failed", JSONObject().put("reason", "package_copy_failed"))
                return
            }
            manifestFiles.forEach { name ->
                val src = appFile(name)
                if (src.exists()) src.copyTo(prevFile(name), overwrite = true)
            }
            Log.i(TAG, "Snapshotted current bundle to prev before trial install.")
            track(LogLevel.INFO, "ota_snapshot_saved", JSONObject().put("version", readMarker()))
        } catch (e: Exception) {
            clearPrev()
            track(LogLevel.ERROR, "ota_snapshot_failed", JSONObject().put("error", e.message))
        }
    }

    fun beginTrial(version: String) {
        writeKv(KEY_TRIAL_VERSION, version)
        writeKv(KEY_TRIAL_ATTEMPTS, "0")
    }

    fun evaluateBoot(activeVersion: String): BootDecision {
        val trial = trialVersion()
        if (trial.isEmpty()) return BootDecision.NORMAL
        if (trial != activeVersion || trial == safeVersion()) {
            clearTrial()
            return BootDecision.NORMAL
        }
        val attempts = recordBootAttempt()
        if (attempts > MAX_TRIAL_BOOT_ATTEMPTS) {
            val restored = restorePrevToActive()
            if (!restored) discardActiveOta()
            markFailed(trial)
            clearTrial()
            Log.w(TAG, "Rolling back '$trial' after $attempts boots (restored_previous=$restored).")
            track(
                LogLevel.ERROR,
                "ota_bundle_rolled_back",
                JSONObject()
                    .put("failed_version", trial)
                    .put("attempts", attempts)
                    .put("restored_previous", restored)
            )
            return BootDecision.ROLLED_BACK
        }
        Log.i(TAG, "Trial boot of '$trial' (attempt $attempts of $MAX_TRIAL_BOOT_ATTEMPTS).")
        track(
            LogLevel.INFO,
            "ota_bundle_trial_boot",
            JSONObject().put("version", trial).put("attempt", attempts)
        )
        return BootDecision.TRIAL
    }

    fun markSafe(version: String) {
        if (version.isEmpty()) return
        writeKv(KEY_SAFE_VERSION, version)
        if (trialVersion() == version) {
            clearTrial()
            clearPrev()
            Log.i(TAG, "Marked bundle '$version' safe.")
            track(LogLevel.INFO, "ota_bundle_marked_safe", JSONObject().put("version", version))
        }
    }

    fun markFailed(version: String) {
        if (version.isEmpty()) return
        val current = failedVersions().toMutableList()
        if (current.contains(version)) return
        current.add(version)
        val capped = current.takeLast(MAX_FAILED_HISTORY)
        writeKv(KEY_FAILED, capped.joinToString(","))
    }

    private fun recordBootAttempt(): Int {
        val next = (readKv(KEY_TRIAL_ATTEMPTS, "0").toIntOrNull() ?: 0) + 1
        writeKv(KEY_TRIAL_ATTEMPTS, next.toString())
        return next
    }

    private fun restorePrevToActive(): Boolean {
        val prevPkg = prevFile(PACKAGE_DIR_NAME)
        if (!prevPkg.exists()) return false
        return try {
            val activePkg = appFile(PACKAGE_DIR_NAME)
            val stagingPkg = appFile(RESTORE_STAGING_DIR_NAME)
            stagingPkg.deleteRecursively()
            stagingPkg.parentFile?.mkdirs()
            if (!prevPkg.copyRecursively(stagingPkg, overwrite = true)) {
                stagingPkg.deleteRecursively()
                return false
            }
            appFile(INSTALL_MARKER_FILE_NAME).delete()
            activePkg.deleteRecursively()
            if (!stagingPkg.renameTo(activePkg)) {
                val copied = stagingPkg.copyRecursively(activePkg, overwrite = true)
                stagingPkg.deleteRecursively()
                if (!copied) return false
            }
            manifestFiles.forEach { name ->
                if (name == INSTALL_MARKER_FILE_NAME) return@forEach
                val p = prevFile(name)
                if (p.exists()) {
                    p.copyTo(appFile(name), overwrite = true)
                } else {
                    appFile(name).delete()
                }
            }
            val prevMarker = prevFile(INSTALL_MARKER_FILE_NAME)
            if (prevMarker.exists()) prevMarker.copyTo(appFile(INSTALL_MARKER_FILE_NAME), overwrite = true)
            clearPrev()
            true
        } catch (e: Exception) {
            track(LogLevel.ERROR, "ota_restore_failed", JSONObject().put("error", e.message))
            false
        }
    }

    private fun discardActiveOta() {
        try {
            appFile(PACKAGE_DIR_NAME).deleteRecursively()
            manifestFiles.forEach { appFile(it).delete() }
            clearPrev()
        } catch (e: Exception) {
            track(LogLevel.ERROR, "ota_discard_failed", JSONObject().put("error", e.message))
        }
    }

    private fun clearPrev() {
        prevFile("").deleteRecursively()
    }

    private fun clearTrial() {
        writeKv(KEY_TRIAL_VERSION, "")
        writeKv(KEY_TRIAL_ATTEMPTS, "0")
    }

    private fun readMarker(): String {
        val f = appFile(INSTALL_MARKER_FILE_NAME)
        return if (f.exists()) f.readText().trim() else ""
    }

    private fun appFile(rel: String): File =
        workspace.open(if (rel.isEmpty()) APP_DIR else "$APP_DIR/$rel")

    private fun prevFile(rel: String): File =
        workspace.open(if (rel.isEmpty()) PREV_DIR_NAME else "$PREV_DIR_NAME/$rel")

    private fun readKv(key: String, default: String = ""): String =
        workspace.getFromSharedPreference(key, default) ?: default

    private fun writeKv(key: String, value: String) {
        workspace.writeToSharedPreferenceSync(key, value)
    }

    private fun track(level: String, label: String, value: JSONObject) {
        try {
            tracker.track(
                LogCategory.LIFECYCLE,
                LogSubCategory.LifeCycle.AIRBORNE,
                level,
                TAG,
                label,
                value
            )
        } catch (e: Exception) {
            Log.e(TAG, "track failed for $label", e)
        }
    }

    companion object {
        private const val TAG = "RollbackStore"
        const val MAX_TRIAL_BOOT_ATTEMPTS = 2
        private const val MAX_FAILED_HISTORY = 20
        private const val KEY_TRIAL_VERSION = "airborne_trial_version"
        private const val KEY_TRIAL_ATTEMPTS = "airborne_trial_attempts"
        private const val KEY_SAFE_VERSION = "airborne_safe_version"
        private const val KEY_FAILED = "airborne_failed_versions"

        fun clearPersistedState(workspace: Workspace) {
            workspace.removeFromSharedPreference(KEY_TRIAL_VERSION)
            workspace.removeFromSharedPreference(KEY_TRIAL_ATTEMPTS)
            workspace.removeFromSharedPreference(KEY_SAFE_VERSION)
            workspace.removeFromSharedPreference(KEY_FAILED)
        }
    }
}
