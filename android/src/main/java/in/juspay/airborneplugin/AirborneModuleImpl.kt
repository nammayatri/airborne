package `in`.juspay.airborneplugin

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.Promise
import com.jakewharton.processphoenix.ProcessPhoenix
import `in`.juspay.airborne.utils.OTAUtils

/**
 * Implementation class that handles the actual Airborne operations.
 * This class is shared between old and new architecture modules.
 */
class AirborneModuleImpl(private val reactContext: ReactApplicationContext) {

    fun readReleaseConfig(namespace: String, promise: Promise) {
        try {
            val config = Airborne.airborneObjectMap[namespace]?.getReleaseConfig()
            promise.resolve(config)
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to read release config: ${e.message}", e)
        }
    }

    fun getFileContent(namespace: String, filePath: String, promise: Promise) {
        try {
            val content = Airborne.airborneObjectMap[namespace]?.getFileContent(filePath)
            promise.resolve(content)
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to read file content: ${e.message}", e)
        }
    }

    fun getBundlePath(namespace: String, promise: Promise) {
        try {
            val path = Airborne.airborneObjectMap[namespace]?.getBundlePath()
            promise.resolve(path)
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to get bundle path: ${e.message}", e)
        }
    }

    fun checkForUpdate(namespace: String, promise: Promise) {
        OTAUtils.runOnBackgroundThread {
            try {
                val airborne = Airborne.airborneObjectMap[namespace]
                if (airborne == null) {
                    promise.reject("AIRBORNE_ERROR", "Airborne not initialized for namespace: $namespace")
                    return@runOnBackgroundThread
                }
                val result = airborne.checkForUpdate()
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("AIRBORNE_ERROR", "Failed to check for update: ${e.message}", e)
            }
        }
    }

    fun downloadUpdate(namespace: String, promise: Promise) {
        try {
            val airborne = Airborne.airborneObjectMap[namespace]
            if (airborne == null) {
                promise.reject("AIRBORNE_ERROR", "Airborne not initialized for namespace: $namespace")
                return
            }
            airborne.downloadUpdate { success ->
                promise.resolve(success)
            }
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to download update: ${e.message}", e)
        }
    }

    fun startBackgroundDownload(namespace: String, promise: Promise) {
        try {
            Airborne.triggerBackgroundDownload(reactContext.applicationContext, namespace)
            promise.resolve(true)
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to start background download: ${e.message}", e)
        }
    }

    fun hasPendingBundleUpdate(namespace: String, promise: Promise) {
        try {
            val airborne = Airborne.airborneObjectMap[namespace]
            if (airborne == null) {
                promise.reject("AIRBORNE_ERROR", "Airborne not initialized for namespace: $namespace")
                return
            }
            promise.resolve(airborne.hasPendingBundleUpdate())
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to check pending bundle update: ${e.message}", e)
        }
    }

    fun reloadApp(namespace: String, promise: Promise) {
        try {
            promise.resolve(null)

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    ProcessPhoenix.triggerRebirth(reactContext.applicationContext)
                } catch (e: Exception) {
                    Log.e("AIRBORNE_ERROR", "Failed to reload app", e)
                }
            }, 200)
        } catch (e: Exception) {
            promise.reject("AIRBORNE_ERROR", "Failed to reload app: ${e.message}", e)
        }
    }
}
