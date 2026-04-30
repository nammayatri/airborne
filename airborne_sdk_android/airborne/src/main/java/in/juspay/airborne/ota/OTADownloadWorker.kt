package `in`.juspay.airborne.ota

import android.content.Context
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

        try {
            val config = readWorkerConfig(applicationContext, namespace)
            if (config == null) {
                Log.w(TAG, "No persisted worker config for '$namespace'. Airborne has never been initialized on this device. Giving up.")
                return@withContext Result.failure()
            }

            val manager = buildEphemeralManager(applicationContext, namespace, config)
            downloadWithManager(manager)
        } catch (e: Exception) {
            Log.e(TAG, "Background download threw for '$namespace'", e)
            retryOrGiveUp("uncaught exception")
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
