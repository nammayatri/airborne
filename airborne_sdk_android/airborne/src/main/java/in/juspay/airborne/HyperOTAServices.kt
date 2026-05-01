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

package `in`.juspay.airborne

import android.content.Context
import androidx.annotation.Keep
import `in`.juspay.airborne.ota.ApplicationManager
import `in`.juspay.airborne.services.OTAServices
import `in`.juspay.airborne.services.Workspace
import java.net.URLEncoder
import java.util.UUID

@Keep
class HyperOTAServices(private val context: Context, workSpacePath: String, appVersion: String, releaseConfigTemplateUrl: String, trackerCallback: TrackerCallback, private val onBootComplete: ((String) -> Unit)? = null, useBundledAssets: Boolean = false, private val fromAirborne: Boolean = true) {
    val workspace: Workspace = Workspace(context, workSpacePath, fromAirborne)
    val otaServices: OTAServices = OTAServices(context, workspace, appVersion, useBundledAssets, trackerCallback, fromAirborne)

    private val resolvedReleaseConfigUrl: String =
        appendStickyToss(workspace, releaseConfigTemplateUrl)

    @Keep
    fun createApplicationManager(dimensions: Map<String, String>? = null, metricsEndpoint: String? = null): ApplicationManager {
        return ApplicationManager(context, resolvedReleaseConfigUrl, otaServices, metricsEndpoint, dimensions, onBootComplete, fromAirborne)
    }

    companion object {
        private const val TOSS_PREFS_KEY = "airborne_toss"
        
        private fun appendStickyToss(workspace: Workspace, url: String): String {
            val toss = workspace.getFromSharedPreference(TOSS_PREFS_KEY, null)
                ?: UUID.randomUUID().toString().also {
                    workspace.writeToSharedPreference(TOSS_PREFS_KEY, it)
                }
            val encoded = URLEncoder.encode(toss, "UTF-8")
            val sep = if (url.contains('?')) "&" else "?"
            return "$url${sep}toss=$encoded"
        }
    }
}
