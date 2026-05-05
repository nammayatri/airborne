package `in`.juspay.airborneplugin

import android.content.Context
import android.util.Log
import androidx.annotation.Keep
import com.jakewharton.processphoenix.ProcessPhoenix
import `in`.juspay.airborne.HyperOTAServices
import `in`.juspay.airborne.LazyDownloadCallback
import `in`.juspay.airborne.TrackerCallback
import `in`.juspay.hyperutil.constants.LogLevel
import org.json.JSONObject
import `in`.juspay.airborne.ota.OTADownloadWorker
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

@Keep
class Airborne(
    context: Context,
    releaseConfigUrl: String,
    private val airborneInterface: AirborneInterface
) {

    constructor(context: Context, releaseConfigUrl: String) : this(context, releaseConfigUrl, object : AirborneInterface() {})

    /**
     * Default no-op TrackerCallback.
     */
    private val trackerCallback = object : TrackerCallback() {

        override fun track(
            category: String,
            subCategory: String,
            level: String,
            label: String,
            key: String,
            value: JSONObject
        ) {
            airborneInterface.onEvent(level, label, key, value, category, subCategory)
        }

        override fun trackException(
            category: String,
            subCategory: String,
            label: String,
            description: String,
            e: Throwable
        ) {
            airborneInterface.onEvent(LogLevel.EXCEPTION, label, description, JSONObject().put("throwable", e), category, subCategory)
        }
    }

    private val hyperOTAServices = HyperOTAServices(
        context,
        airborneInterface.getNamespace(),
        "",
        releaseConfigUrl,
        trackerCallback,
        this::bootComplete
    )

    private val applicationManager = hyperOTAServices.createApplicationManager(airborneInterface.getDimensions())

    init {
        val namespace = airborneInterface.getNamespace()
        val existing = airborneObjectMap.putIfAbsent(namespace, this)
        if (existing != null) {
            Log.w(TAG, "Airborne already initialized for '$namespace'; ignoring duplicate construction")
        }
        applicationManager.shouldUpdate = airborneInterface.enableBootDownload()
        persistWorkerConfig(context, namespace, releaseConfigUrl, airborneInterface.getDimensions())
        applicationManager.loadApplication(namespace, airborneInterface.getLazyDownloadCallback())
    }

    private fun persistWorkerConfig(
        context: Context,
        namespace: String,
        releaseConfigUrl: String,
        dimensions: Map<String, String>
    ) {
        try {
            val dimJson = JSONObject()
            dimensions.forEach { (k, v) -> dimJson.put(k, v) }
            val config = JSONObject()
                .put("releaseConfigUrl", releaseConfigUrl)
                .put("dimensions", dimJson)
                .toString()
            context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
                .edit()
                .putString(WORKER_CONFIG_KEY, config)
                .apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist worker config for namespace '$namespace'", e)
        }
    }

    private fun bootComplete(filePath: String) {
        airborneInterface.startApp(filePath.ifEmpty { "assets://${applicationManager.getBundledIndexPath().ifEmpty { "index.android.bundle" }}" })
    }

    /**
     * @return The path of the index bundle, or asset path fallback if empty.
     */
    @Keep
    fun getBundlePath(): String {
        val filePath = applicationManager.getIndexBundlePath()
        return filePath.ifEmpty { "assets://${applicationManager.getBundledIndexPath().ifEmpty { "index.android.bundle" }}" }
    }

    /**
     * Reads the content of the given file.
     * @param filePath The relative path of the file.
     * @return The content of the file as String.
     */
    @Keep
    fun getFileContent(filePath: String): String {
        return applicationManager.readSplit(filePath)
    }

    /**
     * @return Stringified JSON of the release config.
     */
    @Keep
    fun getReleaseConfig(): String {
        return applicationManager.readReleaseConfig()
    }

    /**
     * Set custom SSL configuration for mTLS support.
     * Call this before network requests are made to enable client certificate authentication.
     *
     * @param sslSocketFactory SSL socket factory configured with client certificate
     * @param trustManager Trust manager for server certificate validation
     */
    @Keep
    fun setSslConfig(sslSocketFactory: SSLSocketFactory, trustManager: X509TrustManager) {
        applicationManager.setSslConfig(sslSocketFactory, trustManager)
    }

    /**
     * Check if an OTA update is available.
     * Delegates to ApplicationManager which handles the network call and version comparison.
     */
    @Keep
    fun checkForUpdate(): String {
        return applicationManager.checkForUpdate()
    }

    /**
     * Download and install the latest OTA bundle.
     * Delegates to ApplicationManager.downloadUpdate() which reuses the same
     * download/install infrastructure as boot-time updates.
     */
    @Keep
    fun downloadUpdate(onComplete: (success: Boolean) -> Unit) {
        applicationManager.downloadUpdate(onComplete = onComplete)
    }

    /**
     * True when a newer bundle is committed to disk but the running JS in V8
     * is still the boot-time one. Hosts should check this on
     * `MainActivity.onCreate` and force a process restart when true — required
     * for OEMs (e.g. OnePlus) that keep the process alive across "kill from
     * recents", which would otherwise leave the old JS pinned in V8.
     */
    @Keep
    fun hasPendingBundleUpdate(): Boolean {
        return applicationManager.hasPendingBundleUpdate()
    }

    companion object {
//        private var initializer: (() -> Airborne)? = null
//
//        /**
//         * Lazily initialized singleton instance.
//         */
//        @JvmStatic
//        val instance: Airborne by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
//            initializer?.invoke()
//                ?: throw IllegalStateException("AirborneReact initializer not set. Call init() first.")
//        }
//
//        /**
//         * Initializes the AirborneReact singleton.
//         */
//        @JvmStatic
//        fun init(
//            context: Context,
//            appId: String,
//            indexFileName: String,
//            appVersion: String,
//            releaseConfigTemplateUrl: String,
//            headers: Map<String, String>? = null,
//            lazyDownloadCallback: LazyDownloadCallback? = null,
//            trackerCallback: TrackerCallback? = null
//        ) {
//            initializer = {
//                Airborne(
//                    context,
//                    appId,
//                    indexFileName,
//                    appVersion,
//                    releaseConfigTemplateUrl,
//                    headers,
//                    lazyDownloadCallback ?: defaultLazyCallback,
//                    trackerCallback ?: defaultTrackerCallback
//                )
//            }
//        }

        private const val TAG = "Airborne"
        internal const val WORKER_CONFIG_KEY = "airborne_worker_config"

        val airborneObjectMap: MutableMap<String, Airborne> = java.util.concurrent.ConcurrentHashMap()

        /**
         * Default LazyDownloadCallback implementation.
         */
        val defaultLazyCallback = object : LazyDownloadCallback {
            override fun fileInstalled(filePath: String, success: Boolean) {
                // Default implementation: log the file installation status
                if (success) {
                    println("AirborneReact: File installed successfully: $filePath")
                } else {
                    println("AirborneReact: File installation failed: $filePath")
                }
            }

            override fun lazySplitsInstalled(success: Boolean) {
                // Default implementation: log the lazy splits installation status
                if (success) {
                    println("AirborneReact: Lazy splits installed successfully")
                } else {
                    println("AirborneReact: Lazy splits installation failed")
                }
            }
        }

        /**
         * Trigger a background OTA download via WorkManager.
         * Call from FCM service or any context — does not require RN.
         */
        @JvmStatic
        fun triggerBackgroundDownload(context: Context, namespace: String) {
            OTADownloadWorker.enqueue(context, namespace)
        }

        /**
         * If a newer bundle is committed to disk but the running JS in V8
         * is still the boot-time one, kill the process and relaunch via
         * ProcessPhoenix so the new bundle takes effect on the next boot.
         *
         * @return true if a restart was triggered, false otherwise.
         */
        @JvmStatic
        fun applyPendingBundleUpdate(context: Context, namespace: String): Boolean {
            val airborne = airborneObjectMap[namespace] ?: return false
            return try {
                if (airborne.hasPendingBundleUpdate()) {
                    Log.i(TAG, "Pending bundle update for '$namespace'; restarting process via ProcessPhoenix")
                    ProcessPhoenix.triggerRebirth(context)
                    true
                } else {
                    false
                }
            } catch (e: Exception) {
                Log.e(TAG, "applyPendingBundleUpdate failed", e)
                false
            }
        }
    }
}
