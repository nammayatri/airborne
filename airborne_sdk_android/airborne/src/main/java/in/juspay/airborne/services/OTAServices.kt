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

package `in`.juspay.airborne.services

import android.content.Context
import android.util.Log
import `in`.juspay.airborne.TrackerCallback
import `in`.juspay.airborne.constants.Labels
import `in`.juspay.airborne.constants.LogCategory
import `in`.juspay.airborne.constants.LogLevel
import `in`.juspay.airborne.constants.LogSubCategory
import `in`.juspay.airborne.constants.OTAConstants
import org.json.JSONObject

class OTAServices(private val ctx: Context, val workspace: Workspace, val cleanUpValue: String, val useBundledAssets: Boolean, val trackerCallback: TrackerCallback, val fromAirborne: Boolean = true) {
    val fileProviderService: FileProviderService = FileProviderService(this)
    val remoteAssetService: RemoteAssetService = RemoteAssetService(this)
    var clientId: String? = null

    /**
     * False when an app-upgrade wipe did not verify clean. Callers gate disk
     * reads and `downloadUpdate` on this so surviving files from the previous
     * binary aren't used or extended. Marker is not persisted on failure so
     * the next boot retries.
     */
    @Volatile
    var canTrustDisk: Boolean = true
        private set

    init {
        firstTimeCleanup()
    }

    private fun firstTimeCleanup() {
        val prevBuildId = workspace.getFromSharedPreference(OTAConstants.OTA_BUILD_ID, "__failed")
        if (prevBuildId == cleanUpValue) {
            return
        }

        Log.i(TAG, "firstTimeCleanup: app upgrade detected (prev='$prevBuildId' new='$cleanUpValue'); wiping workspace '${workspace.path}'")
        trackerCallback.track(
            LogCategory.LIFECYCLE,
            LogSubCategory.LifeCycle.AIRBORNE,
            LogLevel.INFO,
            Labels.Airborne.FIRST_TIME_SETUP,
            "started",
            JSONObject()
                .put("status", "started")
                .put("prev_build_id", prevBuildId ?: "")
                .put("new_build_id", cleanUpValue)
        )

        val cleanedSuccessfully = try {
            workspace.clean(ctx)
        } catch (e: Exception) {
            Log.e(TAG, "firstTimeCleanup: exception during workspace.clean()", e)
            trackerCallback.trackAndLogException(
                TAG,
                LogCategory.LIFECYCLE,
                LogSubCategory.LifeCycle.AIRBORNE,
                Labels.Airborne.FIRST_TIME_SETUP,
                "Exception in firstTimeCleanUp",
                e
            )
            false
        }

        if (cleanedSuccessfully) {
            // Persist marker only after the wipe verified clean — otherwise
            // next boot skips the retry and loads stale state.
            workspace.writeToSharedPreference(OTAConstants.OTA_BUILD_ID, cleanUpValue)
            workspace.removeFromSharedPreference("asset_metadata.json")
            Log.i(TAG, "firstTimeCleanup: completed; persisted buildId='$cleanUpValue'")
            trackerCallback.track(
                LogCategory.LIFECYCLE,
                LogSubCategory.LifeCycle.AIRBORNE,
                LogLevel.INFO,
                Labels.Airborne.FIRST_TIME_SETUP,
                "completed",
                JSONObject().put("status", "completed")
            )
        } else {
            canTrustDisk = false
            Log.e(TAG, "firstTimeCleanup: FAILED — wipe did not verify clean; forcing bundled this boot, marker NOT persisted, will retry next boot")
            trackerCallback.track(
                LogCategory.LIFECYCLE,
                LogSubCategory.LifeCycle.AIRBORNE,
                LogLevel.ERROR,
                Labels.Airborne.FIRST_TIME_SETUP,
                "failed_forcing_bundled",
                JSONObject()
                    .put("status", "failed_forcing_bundled")
                    .put("prev_build_id", prevBuildId ?: "")
                    .put("new_build_id", cleanUpValue)
            )
        }
    }

    companion object {
        const val TAG = "OTAServices"
    }
}
