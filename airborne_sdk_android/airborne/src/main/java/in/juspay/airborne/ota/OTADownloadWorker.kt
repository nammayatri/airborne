package `in`.juspay.airborne.ota

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import `in`.juspay.airborne.HyperOTAServices
import `in`.juspay.airborne.TrackerCallback
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import android.os.Process as AndroidProcess

/**
 * WorkManager worker for background OTA bundle downloads.
 * Triggered by FCM push notifications — survives process death,
 * retries with exponential backoff, and uses the long `downloadUpdate`
 * timeout rather than the short boot timeout so a 30MB bundle can
 * actually finish installing on the same run.
 *
 * Always builds a throwaway `ApplicationManager` from the persisted
 * namespace config in SharedPreferences and drives the download through
 * it. If the host Activity is alive concurrently, the SDK's process-wide
 * `RUNNING_UPDATE_TASKS` + `CONTEXT_MAP` deduplicate the install. The
 * new bundle takes effect on the next cold start, when `loadApplication`
 * reads the latest committed package from disk.
 */
class OTADownloadWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val namespace = inputData.getString(KEY_NAMESPACE)
        if (namespace == null) {
            Log.e(TAG, "No namespace provided")
            return@withContext Result.failure()
        }

        Log.d(TAG, "Starting background OTA download for namespace: $namespace (attempt ${runAttemptCount + 1}/$MAX_ATTEMPTS)")

        val config = readWorkerConfig(applicationContext, namespace)
        if (config == null) {
            Log.w(TAG, "No persisted worker config for '$namespace'. Airborne has never been initialized on this device. Giving up.")
            return@withContext Result.failure()
        }

        val manager = buildEphemeralManager(applicationContext, namespace, config)

        val markerBefore = manager.readInstallMarkerVersion()

        val result = try {
            downloadWithManager(manager)
        } catch (e: Exception) {
            Log.e(TAG, "Background download threw for '$namespace'", e)
            retryOrGiveUp("uncaught exception")
        }

        val markerAfter = manager.readInstallMarkerVersion()
        val didInstall = markerAfter.isNotEmpty() && markerAfter != markerBefore
        Log.d(TAG, "doWork finished: result=${result.javaClass.simpleName} markerBefore='$markerBefore' markerAfter='$markerAfter' didInstall=$didInstall")

        if (result == Result.success() && didInstall) {
            scheduleSilentKillIfBackground(applicationContext)
        }

        result
    }

    /**
     * Posts a delayed kill to the main thread. The 500ms delay lets WorkManager
     * commit the success state to disk before we die — without it, the work can
     * be marked as KEEP_ALIVE_FAILED and retried unnecessarily. We re-check the
     * foreground state at kill time in case the user opened the app in the
     * intervening window.
     */
    private fun scheduleSilentKillIfBackground(context: Context) {
        Handler(Looper.getMainLooper()).postDelayed({
            if (isAnyActivityVisible(context)) {
                Log.d(TAG, "Skipping silent kill — an activity is visible; MainActivity guard will handle on next reopen")
                return@postDelayed
            }
            Log.i(TAG, "OTA installed and no UI visible; killing process for clean cold-start on next launch")
            AndroidProcess.killProcess(AndroidProcess.myPid())
        }, KILL_DELAY_MS)
    }

    /**
     * True iff this process currently has any user-visible UI. Uses the
     * `RunningAppProcessInfo.importance` heuristic: anything below
     * `IMPORTANCE_SERVICE` (300) implies an activity that the user can see.
     * Defaults to true on failure so we err on the side of NOT killing.
     */
    private fun isAnyActivityVisible(context: Context): Boolean {
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return true
            val processes = am.runningAppProcesses ?: return true
            val mine = processes.find { it.pid == AndroidProcess.myPid() } ?: return true
            mine.importance < ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE
        } catch (e: Exception) {
            Log.w(TAG, "isAnyActivityVisible check failed; assuming true", e)
            true
        }
    }

    private suspend fun downloadWithManager(manager: ApplicationManager): Result {
        return suspendCoroutine { continuation ->
            manager.downloadUpdate { success ->
                if (success) {
                    Log.d(TAG, "Background download completed (no retry needed)")
                    continuation.resume(Result.success())
                } else {
                    continuation.resume(retryOrGiveUp("downloadUpdate reported failure"))
                }
            }
        }
    }

    /**
     * Bound WorkManager's retry budget. Transient failures (network blip,
     * server flake) get a handful of attempts with exponential backoff;
     * persistent failures eventually return Result.failure() so the worker
     * doesn't churn forever on a device that, e.g., has lost its Airborne
     * credentials or can't resolve DNS.
     */
    private fun retryOrGiveUp(reason: String): Result {
        val nextAttempt = runAttemptCount + 1
        return if (nextAttempt >= MAX_ATTEMPTS) {
            Log.e(TAG, "Giving up after $nextAttempt attempts ($reason)")
            Result.failure()
        } else {
            Log.w(TAG, "Will retry (attempt $nextAttempt/$MAX_ATTEMPTS): $reason")
            Result.retry()
        }
    }

    private data class WorkerConfig(val releaseConfigUrl: String, val dimensions: Map<String, String>)

    private fun readWorkerConfig(context: Context, namespace: String): WorkerConfig? {
        return try {
            val raw = context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
                .getString(WORKER_CONFIG_KEY, null) ?: return null
            val json = JSONObject(raw)
            val url = json.getString("releaseConfigUrl")
            val dims = mutableMapOf<String, String>()
            json.optJSONObject("dimensions")?.let { d ->
                d.keys().forEach { k -> dims[k] = d.getString(k) }
            }
            WorkerConfig(url, dims)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read worker config for '$namespace'", e)
            null
        }
    }

    private fun buildEphemeralManager(
        context: Context,
        namespace: String,
        config: WorkerConfig
    ): ApplicationManager {
        val tracker = object : TrackerCallback() {
            override fun track(
                category: String,
                subCategory: String,
                level: String,
                label: String,
                key: String,
                value: JSONObject
            ) {
                Log.d("$TAG/track", "$category/$subCategory/$level $label $key $value")
            }

            override fun trackException(
                category: String,
                subCategory: String,
                label: String,
                description: String,
                e: Throwable
            ) {
                Log.e("$TAG/trackEx", "$category/$subCategory $label $description", e)
            }
        }
        val services = HyperOTAServices(
            context,
            namespace,
            "",
            config.releaseConfigUrl,
            tracker,
            null,
            false,
            true
        )
        return services.createApplicationManager(config.dimensions)
    }

    companion object {
        private const val TAG = "OTADownloadWorker"
        private const val KEY_NAMESPACE = "namespace"
        private const val WORK_NAME_PREFIX = "ota_download_"
        private const val WORK_TAG = "airborne_ota"
        private const val WORKER_CONFIG_KEY = "airborne_worker_config"
        private const val MAX_ATTEMPTS = 3
        private const val KILL_DELAY_MS = 500L

        /**
         * Enqueue a background OTA download job.
         * Uses REPLACE so a fresh FCM push always supersedes any stuck-on-no-network job.
         * `UpdateTask` is idempotent per on-disk version via `RUNNING_UPDATE_TASKS`.
         */
        fun enqueue(context: Context, namespace: String) {
            val request = OneTimeWorkRequestBuilder<OTADownloadWorker>()
                .setInputData(workDataOf(KEY_NAMESPACE to namespace))
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .setBackoffCriteria(
                    BackoffPolicy.EXPONENTIAL,
                    30,
                    TimeUnit.SECONDS
                )
                .addTag(WORK_TAG)
                .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(
                    "$WORK_NAME_PREFIX$namespace",
                    ExistingWorkPolicy.REPLACE,
                    request
                )

            Log.d(TAG, "Enqueued background download for '$namespace'")
        }
    }
}
