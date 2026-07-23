package `in`.juspay.airborne.analytics

import android.content.Context
import android.net.Uri
import org.json.JSONObject

object OtaFunnel {
    private const val URL_KEY = "chime_url"
    private const val KEY_KEY = "chime_key"
    private const val ORG_KEY = "chime_org"
    private const val APP_KEY = "chime_app"
    private const val JOB_ID_KEY = "chime_job_id"

    fun persistConfig(
        context: Context,
        namespace: String,
        url: String?,
        key: String?,
        releaseConfigUrl: String?
    ) {
        if (url.isNullOrEmpty() || key.isNullOrEmpty()) return
        val release = parseReleaseConfigUrl(releaseConfigUrl)
        context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
            .edit()
            .putString(URL_KEY, url)
            .putString(KEY_KEY, key)
            .putString(ORG_KEY, release.first)
            .putString(APP_KEY, release.second)
            .apply()
    }

    fun persistJobId(context: Context, namespace: String, jobId: String?) {
        val editor = context.getSharedPreferences(namespace, Context.MODE_PRIVATE).edit()
        if (jobId.isNullOrEmpty()) {
            editor.remove(JOB_ID_KEY)
        } else {
            editor.putString(JOB_ID_KEY, jobId)
        }
        editor.apply()
    }

    fun post(
        context: Context,
        namespace: String,
        stage: String,
        version: String? = null,
        errorCode: String? = null,
        async: Boolean,
        terminal: Boolean = false
    ) {
        val prefs = context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
        val baseUrl = prefs.getString(URL_KEY, null) ?: return
        val key = prefs.getString(KEY_KEY, null) ?: return
        val jobId = prefs.getString(JOB_ID_KEY, null) ?: return

        val body = JSONObject()
            .put("job_id", jobId)
            .put("stage", stage)
            .put("package", context.packageName)
            .put("airborne_org", prefs.getString(ORG_KEY, null).orEmpty())
            .put("airborne_app", prefs.getString(APP_KEY, null).orEmpty())
        if (version != null) body.put("version", version)
        if (errorCode != null) body.put("error_code", errorCode)
        readCustomerId(context)?.let { body.put("user_id", it) }

        if (terminal) {
            prefs.edit().remove(JOB_ID_KEY).apply()
        }

        if (async) {
            Chime.postFunnelAsync(baseUrl, key, body)
        } else {
            Chime.postFunnel(baseUrl, key, body)
        }
    }

    private fun parseReleaseConfigUrl(releaseConfigUrl: String?): Pair<String, String> {
        if (releaseConfigUrl.isNullOrEmpty()) return "" to ""
        val segments = try {
            Uri.parse(releaseConfigUrl).pathSegments.filter { it.isNotEmpty() }
        } catch (e: Exception) {
            emptyList<String>()
        }
        if (segments.size < 2) return "" to ""
        return segments[segments.size - 2] to segments[segments.size - 1]
    }

    private val INVALID_USER_IDS = setOf("NO_CUSTOMER_ID", "__failed", "(failed)")

    private fun readCustomerId(context: Context): String? {
        val id = context.getSharedPreferences("godel", Context.MODE_PRIVATE)
            .getString("CUSTOMER_ID", null)?.trim()
        return if (id.isNullOrEmpty() || id in INVALID_USER_IDS) null else id
    }
}
