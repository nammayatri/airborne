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

import android.content.Context
import android.util.Log
import `in`.juspay.airborne.LazyDownloadCallback
import `in`.juspay.airborne.network.NetUtils
import `in`.juspay.airborne.network.OTANetUtils
import `in`.juspay.airborne.ota.Constants.APP_DIR
import `in`.juspay.airborne.ota.Constants.CONFIG_FILE_NAME
import `in`.juspay.airborne.ota.Constants.DEFAULT_CONFIG
import `in`.juspay.airborne.ota.Constants.DEFAULT_PKG
import `in`.juspay.airborne.ota.Constants.DEFAULT_RESOURCES
import `in`.juspay.airborne.ota.Constants.INSTALL_MARKER_FILE_NAME
import `in`.juspay.airborne.ota.Constants.PACKAGE_DIR_NAME
import `in`.juspay.airborne.ota.Constants.PACKAGE_MANIFEST_FILE_NAME
import `in`.juspay.airborne.ota.Constants.RC_VERSION_FILE_NAME
import `in`.juspay.airborne.ota.Constants.RESOURCES_DIR_NAME
import `in`.juspay.airborne.ota.Constants.RESOURCES_FILE_NAME
import `in`.juspay.airborne.services.OTAServices
import `in`.juspay.airborne.utils.OTAUtils
import `in`.juspay.airborne.constants.LogCategory
import `in`.juspay.airborne.constants.LogLevel
import `in`.juspay.airborne.constants.LogSubCategory
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentMap
import java.util.concurrent.Future
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

class ApplicationManager(
    private val ctx: Context,
    private var releaseConfigTemplateUrl: String,
    private val otaServices: OTAServices,
    private val metricsEndPoint: String? = null,
    private val rcHeaders: Map<String, String>? = null,
    private val onBootComplete: ((String) -> Unit)? = null,
    private val fromAirborne: Boolean = true
) {
    @Volatile
    var shouldUpdate = true
    private lateinit var netUtils: NetUtils
    @Volatile
    private var releaseConfig: ReleaseConfig? = null
    @Volatile
    private var loadedPackageVersion: String? = null
    @Volatile
    private var lastUpdateResult: UpdateResult? = null
    private val loadWaitTask = WaitTask()
    private val indexPathWaitTask = WaitTask()
    private val workspace = otaServices.workspace
    private val tracker = otaServices.trackerCallback
    private var indexFolderPath = ""
    private var sessionId: String? = null
    private var rcCallback: ReleaseConfigCallback? = null

    @Volatile
    private var pendingSslConfig: Pair<SSLSocketFactory, X509TrustManager>? = null

    /**
     * Install a custom SSL socket factory + trust manager pair on the OTA
     * network client. Used for mTLS / certificate pinning when fetching the
     * release config and OTA assets.
     *
     * Safe to call before the SDK has performed its first OTA request — the
     * config is queued and applied once the underlying NetUtils is created.
     */
    fun setSslConfig(sslSocketFactory: SSLSocketFactory, trustManager: X509TrustManager) {
        if (::netUtils.isInitialized) {
            netUtils.setSslConfig(sslSocketFactory, trustManager)
        } else {
            pendingSslConfig = sslSocketFactory to trustManager
        }
    }

    private fun applyPendingSslConfig() {
        pendingSslConfig?.let { (sf, tm) ->
            netUtils.setSslConfig(sf, tm)
            pendingSslConfig = null
        }
    }

    /**
     * Register or refresh this client's context in the shared CONTEXT_MAP.
     * @return Pair of (initialized: whether another context already existed, contextRef: the lock object)
     */
    private fun ensureContext(clientId: String): Pair<Boolean, Any> {
        val newRef = WeakReference(ctx)
        val currentRef = CONTEXT_MAP[clientId]
        val initialized = if (currentRef == null) {
            CONTEXT_MAP.putIfAbsent(clientId, newRef) != null
        } else if (currentRef.get() == null) {
            !CONTEXT_MAP.replace(clientId, currentRef, newRef)
        } else {
            true
        }
        val contextRef = CONTEXT_MAP[clientId] ?: newRef
        return Pair(initialized, contextRef)
    }

    fun loadApplication(
        unSanitizedClientId: String,
        lazyDownloadCallback: LazyDownloadCallback? = null
    ) {
        doAsync {
            otaServices.clientId = unSanitizedClientId
            val clientId = sanitizeClientId(unSanitizedClientId)
            trackInfo("init", JSONObject().put("client_id", clientId))
            val startTime = System.currentTimeMillis()
            try {
                if (releaseConfig == null) {
                    val (initialized, contextRef) = ensureContext(clientId)
                    releaseConfig = readReleaseConfig(contextRef)
                    if (shouldUpdate) {
                        releaseConfig =
                            tryUpdate(clientId, initialized, contextRef, lazyDownloadCallback)
                    } else {
                        Log.d(TAG, "Updates disabled, running w/o updating.")
                    }
                }
                val rc = releaseConfig
                if (rc == null) {
                    Log.w(TAG, "No release config available (no disk cache, no bundled asset). Skipping load.")
                } else {
                    val resolvedIndexPath = getIndexFilePath(rc.pkg.index?.filePath ?: "")
                    if (resolvedIndexPath.isEmpty()) {
                        indexPathWaitTask.complete()
                        throw IllegalStateException("index split not found on disk.")
                    }
                    val internalPkgPresent =
                        readFromInternalStorage(PACKAGE_MANIFEST_FILE_NAME).isNotEmpty()
                    if (internalPkgPresent) {
                        val markerVersion = readFromInternalStorage(INSTALL_MARKER_FILE_NAME)
                        if (markerVersion != rc.pkg.version) {
                            otaServices.fileProviderService.updateFile(
                                "$APP_DIR/$PACKAGE_MANIFEST_FILE_NAME", ByteArray(0)
                            )
                            indexPathWaitTask.complete()
                            throw IllegalStateException(
                                "install marker mismatch (pkg=${rc.pkg.version} marker=$markerVersion); discarded internal pkg.json."
                            )
                        }
                    }
                    indexFolderPath = resolvedIndexPath
                    indexPathWaitTask.complete()
                    trackBoot(rc, startTime)
                    Log.d(TAG, "Loading package version: ${rc.pkg.version}")
                    loadedPackageVersion = rc.pkg.version
                    loadWaitTask.complete()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Critical exception while loading app! $e")
                trackError(
                    LogLabel.APP_LOAD_EXCEPTION,
                    "Exception raised while loading application.",
                    e
                )
            } finally {
                indexPathWaitTask.complete()
                loadWaitTask.complete()
                onBootComplete?.let { it(indexFolderPath) } // TODO: this has to be changed
                logTimeTaken(startTime, "loadApplication")
            }
        }
    }

    fun getIndexBundlePath(): String {
        indexPathWaitTask.get()
        return indexFolderPath
    }

    fun setReleaseConfigCallback(rcCallback: ReleaseConfigCallback) {
        this.rcCallback = rcCallback
    }

    fun getBundledIndexPath(): String {
        return releaseConfig?.pkg?.index?.filePath ?: ""
    }

    private fun tryUpdate(
        clientId: String,
        initialized: Boolean,
        fileLock: Any,
        lazyDownloadCallback: LazyDownloadCallback? = null,
        packageTimeoutOverride: Long = 0L,
        releaseConfigTimeoutOverride: Long = 0L
    ): ReleaseConfig? {
        val startTime = System.currentTimeMillis()
        val url = if (releaseConfigTemplateUrl == "") rcCallback?.getReleaseConfig(false) else releaseConfigTemplateUrl
        netUtils = OTANetUtils(ctx, clientId, otaServices.cleanUpValue)
        netUtils.setTrackMetrics(metricsEndPoint != null)
        applyPendingSslConfig()
        val newTask =
            UpdateTask(
                url ?: releaseConfigTemplateUrl,
                otaServices.fileProviderService,
                releaseConfig,
                fileLock,
                tracker,
                netUtils,
                rcHeaders,
                lazyDownloadCallback,
                fromAirborne,
                packageTimeoutOverride,
                releaseConfigTimeoutOverride
            )
        val runningTask = RUNNING_UPDATE_TASKS.putIfAbsent(clientId, newTask) ?: newTask
        if (runningTask == newTask) {
            Log.d(TAG, "No running update tasks for '$clientId', starting new task.")
            val pkg = runningTask.copyTempPkg()
            pkg?.let { p ->
                releaseConfig = releaseConfig?.copy(pkg = p)
                runningTask.updateReleaseConfig(releaseConfig)
            }
            newTask.run { updateResult, persistentState ->
                Log.d(TAG, "Running onFinish for '$clientId'")
                if (!initialized) {
                    runCleanUp(persistentState, updateResult)
                }
                val packageUpdated = when (updateResult) {
                    is UpdateResult.Ok ->
                        updateResult.releaseConfig.pkg.version != releaseConfig?.pkg?.version

                    else -> false
                }
                RUNNING_UPDATE_TASKS.remove(clientId)
                logTimeTaken(startTime, "Update task finished for '$clientId'.")
                postMetrics(newTask.updateUUID, packageUpdated)
            }
        } else {
            Log.d(TAG, "Update task already running for '$clientId'.")
        }
        val uresult = runningTask.await(tracker)
        lastUpdateResult = uresult
        trackUpdateResult(uresult)
        val rc = when (uresult) {
            is UpdateResult.Ok -> uresult.releaseConfig
            is UpdateResult.PackageUpdateTimeout ->
                uresult.releaseConfig ?: releaseConfig

            UpdateResult.Error.RCFetchError ->
                if (rcCallback != null && rcCallback?.shouldRetry() == true) {
                    Log.d(
                        TAG,
                        "Failed to fetch release config, re-trying in release mode."
                    )
                    runningTask.awaitOnFinish()
                    releaseConfigTemplateUrl = rcCallback?.getReleaseConfig(true) ?: releaseConfigTemplateUrl
                    tryUpdate(clientId, true, fileLock, lazyDownloadCallback, packageTimeoutOverride)
                } else {
                    releaseConfig
                }

            else -> releaseConfig
        }
        logTimeTaken(startTime, "tryUpdate")
        return rc
    }

    fun setSessionId(sessionId: String?) {
        this.sessionId = sessionId
    }

    private fun postMetrics(updateUUID: String, didUpdatePkg: Boolean) = metricsEndPoint?.let {
        netUtils.postMetrics(it, sessionId ?: "", updateUUID, didUpdatePkg)
    }

    private fun runCleanUp(persistentState: JSONObject, updateResult: UpdateResult) {
        Log.d(TAG, "runCleanUp: updateResult: $updateResult")
        val updatedRc = when (updateResult) {
            is UpdateResult.Ok -> updateResult.releaseConfig
            else -> null
        }
        val pkgSplits = releaseConfig?.pkg?.filePaths ?: emptyList()
        Log.d(TAG, "runCleanUp: Current splits: $pkgSplits")
        val newPkgSplits = updatedRc?.pkg?.filePaths ?: emptyList()
        Log.d(TAG, "runCleanUp: New splits: $newPkgSplits")
        val pkgDir = "app/$PACKAGE_DIR_NAME"
        val resourceFiles =
            releaseConfig?.resources?.filePaths ?: emptyList()
        val newResourceFiles =
            updatedRc?.resources?.filePaths ?: emptyList()
        val splits = if (fromAirborne) {
            pkgSplits + newPkgSplits + resourceFiles + newResourceFiles
        } else {
            (pkgSplits + newPkgSplits)
        }
        cleanUpDir(pkgDir, splits)

        if (!fromAirborne) {
            cleanUpDir("app/$RESOURCES_DIR_NAME", resourceFiles + newResourceFiles)
        }

        val savedPkgDir = persistentState.optJSONObject(StateKey.SAVED_PACKAGE_UPDATE.name)
            ?.optString("dir")
        val savedResDir = persistentState.optJSONObject(StateKey.SAVED_RESOURCE_UPDATE.name)
            ?.optString("dir")
        val cacheDirs = (workspace.cacheRoot.list()?.toList() ?: ArrayList())
            .map { workspace.openInCache(it) }
        val tmpDirRegex = Regex("temp-.*-\\d+")
        val failures = cacheDirs
            .filter {
                it.isDirectory &&
                    it.name != savedPkgDir &&
                    it.name != savedResDir &&
                    it.name.matches(tmpDirRegex)
            }
            .mapNotNull {
                Log.d(TAG, "Deleting temp directory ${it.name}")
                if (!it.deleteRecursively()) {
                    it.name
                } else {
                    null
                }
            }
        if (failures.isNotEmpty()) {
            val message = "Failed to delete some temporary directories during clean-up."
            trackError(
                LogLabel.CLEAN_UP_ERROR,
                JSONObject().put("message", message).put("failures", failures)
            )
        }
    }

    private fun cleanUpDir(dir: String, requiredFiles: List<String>) {
        Log.d(TAG, "requiredFiles for $dir $requiredFiles")
        val current = otaServices.fileProviderService.listFilesRecursive(dir)?.toList() ?: emptyList()
        val redundant = setDifference(current, requiredFiles)
        if (redundant.isEmpty()) {
            Log.d(TAG, "No clean-up required for dir: $dir")
            return
        }
        val startTime = System.currentTimeMillis()
        val failures = redundant.mapNotNull {
            if (otaServices.fileProviderService.deleteFileFromInternalStorage("$dir/$it")) {
                Log.d(TAG, "Deleted file $it from $dir")
                null
            } else {
                it
            }
        }
        if (failures.isNotEmpty()) {
            trackError(
                LogLabel.CLEAN_UP_ERROR,
                JSONObject()
                    .put("message", "Failed to delete some files during clean up.")
                    .put("failures", failures)
            )
        }

        logTimeTaken(startTime)
    }

    fun readResourceByName(name: String): String {
        val filePath = releaseConfig?.resources?.getResource(name)?.filePath
        val text = filePath?.let { readResourceByFileName(it) } ?: ""
        return text
    }

    fun readSplits(fileNames: String): String {
        val jsonArray = JSONArray(fileNames)
        val list: List<String> = (0 until jsonArray.length()).map { jsonArray.getString(it) }
        return readSplits(list).toString()
    }

    private fun readSplits(filePaths: List<String>): JSONObject {
        val jsonObject = JSONObject()

        val futures = filePaths.map {
            doAsync { it to readSplit(it) }
        }

        futures.forEach { future ->
            val (fileName, content) = future.get()
            jsonObject.put(fileName, content)
        }

        return jsonObject
    }

    private fun readResourceByFileName(filePath: String): String =
        readFile("$RESOURCES_DIR_NAME/$filePath")

    private fun readReleaseConfig(lock: Any): ReleaseConfig? {
        // TODO big change, need to do server change
        synchronized(lock) {
            try {
                var rcVersion = readFromInternalStorage(RC_VERSION_FILE_NAME)
                val (configString, pkgString, resString) = listOf(CONFIG_FILE_NAME, PACKAGE_MANIFEST_FILE_NAME, RESOURCES_FILE_NAME)
                    .map { readFromInternalStorage(it) }

                val bundledRC = if (listOf(configString, pkgString, resString).any { it.isEmpty() }) {
                    val assetContent: String? = try {
                        otaServices.fileProviderService.readFromAssets("release_config.json")
                    } catch (_: Exception) { null }
                    if (assetContent.isNullOrEmpty()) null
                    else ReleaseConfig.deSerialize(assetContent).getOrNull()
                } else {
                    null
                }

                if (rcVersion.isEmpty() && bundledRC != null) {
                    rcVersion = bundledRC.version
                }
                val config = loadConfigComponent(configString, CONFIG_FILE_NAME, bundledRC?.config, DEFAULT_CONFIG, ReleaseConfig::deSerializeConfig)
                val pkg = loadConfigComponent(pkgString, PACKAGE_MANIFEST_FILE_NAME, bundledRC?.pkg, DEFAULT_PKG, ReleaseConfig::deSerializePackage)
                val resources = loadConfigComponent(resString, RESOURCES_FILE_NAME, bundledRC?.resources, DEFAULT_RESOURCES, ReleaseConfig::deSerializeResources)

                Log.d(TAG, "Local release config loaded.")
                return ReleaseConfig(rcVersion, config, pkg, resources)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to read local release config. $e")
                trackReadReleaseConfigError(e)
            }
        }
        return null
    }

    private fun <T> loadConfigComponent(
        content: String,
        fileName: String,
        bundledValue: T?,
        defaultValue: T,
        deserializer: (String) -> Result<T>
    ): T {
        if (content.isNotEmpty()) {
            deserializer(content).onSuccess { return it }
                .onFailure { trackReadReleaseConfigError(it) }
        }

        return bundledValue
            ?: deserializer(readFromAssets(fileName)).getOrElse { defaultValue }
    }

    private fun trackReadReleaseConfigError(e: Throwable) {
        when (e) {
            is Exception -> {
                val value = JSONObject()
                    .put("error", e.message)
                    .put("stack_trace", Log.getStackTraceString(e))
                trackError("read_release_config_error", value)
            }
        }
    }

    private fun readFromInternalStorage(filePath: String): String =
        otaServices.fileProviderService.readFromInternalStorage("app/$filePath") ?: ""

    private fun readFromAssets(filePath: String): String =
        otaServices.fileProviderService.readFromAssets("app/$filePath") ?: ""

    private fun readFileAsync(filePath: String): Future<String> = doAsync {
        readFile(filePath)
    }

    private fun readFile(filePath: String): String =
        otaServices.fileProviderService.readFromFile("app/$filePath")

    fun readSplit(fileName: String): String {
        return readFile("$PACKAGE_DIR_NAME/$fileName")
    }

    fun readReleaseConfig(): String {
        return releaseConfig?.serialize() ?: ""
    }

    fun getCurrentPackageVersion(): String {
        return releaseConfig?.pkg?.version ?: ""
    }

    /**
     * True when a newer package has been committed to disk (install marker
     * written by the OTA worker) but the running JS bundle is still the one
     * loaded at boot. Hosts should check this on `MainActivity.onCreate` (the
     * one hook that fires when an OEM keeps the process alive across "kill
     * from recents") and trigger a process restart so the new bundle takes
     * effect — V8 has no API to swap the loaded JS in place.
     */
    fun hasPendingBundleUpdate(): Boolean {
        val loaded = loadedPackageVersion ?: return false
        val onDisk = readFromInternalStorage(INSTALL_MARKER_FILE_NAME)
            .takeIf { it.isNotEmpty() } ?: return false
        return loaded != onDisk
    }

    private sealed class RCFetchResult {
        data class Ok(val body: String) : RCFetchResult()
        object NotFound : RCFetchResult()
        data class Error(val msg: String) : RCFetchResult()
    }

    /**
     * Check if an OTA update is available by comparing the local package version
     * with the server's latest release config.
     *
     * @return JSON string: { available, currentVersion, serverVersion, mandatory, error? }
     */
    fun checkForUpdate(): String {
        val currentVersion = getCurrentPackageVersion()
        try {
            when (val result = fetchLatestRCInternal()) {
                is RCFetchResult.NotFound ->
                    return JSONObject()
                        .put("available", false)
                        .put("currentVersion", currentVersion)
                        .put("serverVersion", "")
                        .put("mandatory", false)
                        .toString()
                is RCFetchResult.Error ->
                    return updateCheckResult(currentVersion, error = result.msg)
                is RCFetchResult.Ok -> {
                    val serverRC = JSONObject(result.body)
                    val serverVersion = serverRC.getJSONObject("package").getString("version")
                    val mandatory = serverRC.getJSONObject("config")
                        .optJSONObject("properties")
                        ?.optBoolean("mandatory", false) ?: false

                    val currentVersionInt: Long? = if (currentVersion.isEmpty()) 0L else currentVersion.toLongOrNull()
                    val serverVersionInt: Long? = serverVersion.toLongOrNull()

                    if (currentVersionInt == null || serverVersionInt == null) {
                        Log.w(TAG, "Version parse failure: current='$currentVersion', server='$serverVersion'")
                        return JSONObject()
                            .put("available", false)
                            .put("currentVersion", currentVersion)
                            .put("serverVersion", serverVersion)
                            .put("mandatory", mandatory)
                            .put("error", "Non-numeric version: current='$currentVersion', server='$serverVersion'")
                            .toString()
                    }

                    return JSONObject()
                        .put("available", serverVersionInt > currentVersionInt)
                        .put("currentVersion", currentVersion)
                        .put("serverVersion", serverVersion)
                        .put("mandatory", mandatory)
                        .toString()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "checkForUpdate failed", e)
            return updateCheckResult(currentVersion, error = e.message ?: "Unknown error")
        }
    }

    private fun updateCheckResult(currentVersion: String, error: String): String {
        return JSONObject()
            .put("available", false)
            .put("currentVersion", currentVersion)
            .put("serverVersion", "")
            .put("mandatory", false)
            .put("error", error)
            .toString()
    }

    /**
     * Fetch the latest release config from the server without triggering any download.
     * Uses the SDK's existing network infrastructure (connection pooling, headers, caching).
     * @return Serialized JSON of the server's release config, or null on failure.
     *         Note: also returns null for HTTP 404 (no applicable release). Callers that
     *         need to distinguish "no release" from "transient failure" should use the
     *         internal sealed-result path.
     */
    fun fetchLatestReleaseConfig(): String? = when (val r = fetchLatestRCInternal()) {
        is RCFetchResult.Ok -> r.body
        else -> null
    }

    private fun fetchLatestRCInternal(): RCFetchResult {
        return try {
            val clientId = sanitizeClientId(otaServices.clientId ?: return RCFetchResult.Error("Client ID not set"))
            if (!::netUtils.isInitialized) {
                netUtils = OTANetUtils(ctx, clientId, otaServices.cleanUpValue)
                applyPendingSslConfig()
            }
            val headers = mutableMapOf<String, String>("cache-control" to "no-cache")
            if (!rcHeaders.isNullOrEmpty()) {
                val sortedHeaders = rcHeaders.toSortedMap()
                headers["x-dimension"] = sortedHeaders.entries.joinToString(";") { "${it.key}=${it.value}" }
            }
            val url = if (releaseConfigTemplateUrl == "") rcCallback?.getReleaseConfig(false) else releaseConfigTemplateUrl
            val resp = netUtils.doGet(url ?: releaseConfigTemplateUrl, headers, null, null, null)
            resp.use {
                val body = it.body()
                when {
                    it.isSuccessful && body != null -> RCFetchResult.Ok(body.string())
                    it.code() == 404 -> RCFetchResult.NotFound
                    else -> RCFetchResult.Error("HTTP ${it.code()}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "fetchLatestReleaseConfig failed", e)
            RCFetchResult.Error(e.message ?: "Unknown error")
        }
    }

    /**
     * Download and install the latest OTA update on-demand.
     * Reuses the same download/install infrastructure as boot-time updates.
     *
     * @param timeoutMs Maximum time to wait for the download (default 5 minutes).
     * @param onComplete Called with true on success, false on failure.
     */
    fun downloadUpdate(
        timeoutMs: Long = 600_000L,
        onComplete: (success: Boolean) -> Unit
    ) {
        doAsync {
            try {
                val clientId = sanitizeClientId(otaServices.clientId ?: "")
                val (initialized, contextRef) = ensureContext(clientId)

                if (releaseConfig == null) {
                    releaseConfig = readReleaseConfig(contextRef)
                }

                val versionBefore = releaseConfig?.pkg?.version

                val updatedRC = tryUpdate(clientId, initialized, contextRef, null, timeoutMs, timeoutMs)

                if (updatedRC != null) {
                    releaseConfig = updatedRC
                    indexFolderPath = getIndexFilePath(updatedRC.pkg.index?.filePath ?: "")
                }

                val result = lastUpdateResult
                val success = updatedRC != null && when (result) {
                    is UpdateResult.Ok, UpdateResult.NA -> true
                    null,
                    is UpdateResult.Error,
                    UpdateResult.ReleaseConfigFetchTimeout,
                    is UpdateResult.PackageUpdateTimeout -> false
                }
                val versionAfter = updatedRC?.pkg?.version
                Log.d(
                    TAG,
                    "downloadUpdate: success=$success updateResult=${result?.javaClass?.simpleName} " +
                        "versionBefore=$versionBefore versionAfter=$versionAfter"
                )
                onComplete(success)
            } catch (e: Exception) {
                Log.e(TAG, "downloadUpdate failed", e)
                onComplete(false)
            }
        }
    }

    private fun trackUpdateResult(updateResult: UpdateResult) {
        val result = when (updateResult) {
            is UpdateResult.Ok -> "OK"
            is UpdateResult.PackageUpdateTimeout -> "PACKAGE_TIMEOUT"
            UpdateResult.ReleaseConfigFetchTimeout -> "RELEASE_CONFIG_TIMEOUT"
            UpdateResult.Error.RCFetchError -> "ERROR"
            UpdateResult.Error.Unknown -> "ERROR"
            UpdateResult.NA -> "NA"
        }
        trackInfo("update_result", JSONObject().put("result", result))
    }

    private fun trackBoot(releaseConfig: ReleaseConfig, startTime: Long) {
        val (rcVersion, config, pkg, resources) = releaseConfig
        val rversions = resources.fold(JSONArray()) { acc, v ->
            acc.put(v.fileName)
            acc
        }
        trackInfo(
            "boot",
            JSONObject()
                .put("release_config_version", rcVersion)
                .put("config_version", config.version)
                .put("package_version", pkg?.version)
                .put("resource_versions", rversions)
                .put("time_taken", System.currentTimeMillis() - startTime)
        )
    }

    private fun trackInfo(label: String, value: JSONObject) {
        trackGeneric(label, value, LogLevel.INFO)
    }

    private fun trackError(label: String, msg: String, e: Exception? = null) {
        val value = JSONObject().put("message", msg)
        e?.let { value.put("stack_trace", Log.getStackTraceString(e)) }
        trackError(label, value)
    }

    private fun trackError(label: String, value: JSONObject) {
        trackGeneric(label, value, LogLevel.ERROR)
    }

    private fun trackGeneric(label: String, value: JSONObject, level: String) {
        tracker.track(
            LogCategory.LIFECYCLE,
            LogSubCategory.LifeCycle.AIRBORNE,
            level,
            TAG,
            label,
            value
        )
    }

    private fun logTimeTaken(startTime: Long, label: String? = null) {
        val totalTime = System.currentTimeMillis() - startTime
        val msg = "Time ${totalTime}ms"
        if (label != null) {
            Log.d(TAG, "$label $msg")
        } else {
            Log.d(TAG, msg)
        }
    }

    enum class StateKey {
        SAVED_PACKAGE_UPDATE,
        SAVED_RESOURCE_UPDATE
    }

    private object LogLabel {
        const val APP_LOAD_EXCEPTION = "app_load_exception"
        const val CLEAN_UP_ERROR = "clean_up_error"
    }

    private fun getIndexFilePath(fileName: String): String {
        val file =
            otaServices.fileProviderService.getFileFromInternalStorage("app/$PACKAGE_DIR_NAME/$fileName")
        if (file.exists()) {
            return file.absolutePath
        }
        return ""
    }

    companion object {
        const val TAG = "ApplicationManager"
        private val CONTEXT_MAP:
            ConcurrentMap<String, WeakReference<Context>> = ConcurrentHashMap()
        private val RUNNING_UPDATE_TASKS:
            ConcurrentMap<String, UpdateTask> = ConcurrentHashMap()

        private fun <V> doAsync(callable: Callable<V>): Future<V> =
            OTAUtils.doAsync(callable)

        // Returns set difference, i.e. A - B
        private fun <V> setDifference(a: List<V>, b: List<V>): List<V> {
            return a.toSet().minus(b.toSet()).toList()
        }

        private fun sanitizeClientId(clientId: String) = clientId.split('_')[0].lowercase()
    }
}

interface ReleaseConfigCallback {
    fun shouldRetry(): Boolean
    fun getReleaseConfig(fetchFailed: Boolean): String
}
