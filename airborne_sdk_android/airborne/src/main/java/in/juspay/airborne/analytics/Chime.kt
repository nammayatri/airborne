package `in`.juspay.airborne.analytics

import android.util.Log
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object Chime {
    private const val TAG = "AirborneChime"
    private val JSON = MediaType.parse("application/json; charset=utf-8")
    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .build()

    fun postFunnel(baseUrl: String, key: String, body: JSONObject) {
        val request = buildRequest(baseUrl, key, body) ?: return
        try {
            client.newCall(request).execute().use { response ->
                logIfUnsuccessful(body, response)
            }
        } catch (e: Exception) {
            Log.w(TAG, "funnel post failed", e)
        }
    }

    fun postFunnelAsync(baseUrl: String, key: String, body: JSONObject) {
        val request = buildRequest(baseUrl, key, body) ?: return
        try {
            client.newCall(request).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    Log.w(TAG, "funnel post failed", e)
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use { logIfUnsuccessful(body, it) }
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "funnel post failed", e)
        }
    }

    private fun buildRequest(baseUrl: String, key: String, body: JSONObject): Request? {
        if (baseUrl.isEmpty() || key.isEmpty()) return null
        return try {
            Request.Builder()
                .url(baseUrl.trimEnd('/') + "/funnel")
                .addHeader("Content-Type", "application/json")
                .addHeader("X-Event-Key", key)
                .post(RequestBody.create(JSON, body.toString()))
                .build()
        } catch (e: Exception) {
            Log.w(TAG, "funnel request build failed", e)
            null
        }
    }

    private fun logIfUnsuccessful(body: JSONObject, response: Response) {
        if (!response.isSuccessful) {
            Log.w(TAG, "funnel ${body.optString("stage")} -> ${response.code()}")
        }
    }
}
