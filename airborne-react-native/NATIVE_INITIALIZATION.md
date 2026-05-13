# Airborne Native Initialization Guide

This guide explains how to initialize Airborne in native code and use it from React Native. The implementation is compatible with both the old and new React Native architectures.

## Overview

Airborne is initialized once in native code (iOS/Android) when the app starts. After initialization, the React Native module can access the Airborne instance to read config files and perform other operations.

## Android Setup

### 1. Add Airborne maven

In your root's `android/build.gradle`:

```gradle
allprojects {
    repositories {
        maven { url "https://maven.juspay.in/hyper-sdk/" }
        // ... other mavens
    }
}
```


### 2. Initialize Airborne in MainApplication

In your `MainApplication.kt` (or `.java`), initialize Airborne in the `onCreate` method.
And extend the `AirborneReactNativeHost` and assign it to the `ReactNativeHost`'s object in your `MainApplication` and override `getJSBundleFile` method of `AirborneReactNativeHost` and return `airborne.getBundlePath()` from there.

```kotlin
import android.app.Application
import `in`.juspay.airborneplugin.Airborne
import `in`.juspay.airborneplugin.AirborneInterface
import `in`.juspay.airborne.LazyDownloadCallback
import `in`.juspay.airborneplugin.AirborneReactNativeHost

class MainApplication : Application(), ReactApplication {

    private var bundlePath: String? = null
    var isBootComplete = false
    var bootCompleteListener: (() -> Unit)? = null
    private lateinit var airborne: Airborne
    override val reactNativeHost: ReactNativeHost =
        object : AirborneReactNativeHost(this@MainApplication) {
            override fun getPackages(): List<ReactPackage> =
                PackageList(this).packages.apply {
                    // Packages that cannot be autolinked yet can be added manually here, for example:
                    // add(MyReactNativePackage())
                }

            override fun getJSBundleFile(): String? {
                // This is delayed until mainActivity is created.
                // Make sure react is not booted until after bundlePath is created
                return airborne.getBundlePath()
            }

            override fun getJSMainModuleName(): String = "index"

            override fun getUseDeveloperSupport(): Boolean = BuildConfig.DEBUG

            override val isNewArchEnabled: Boolean = BuildConfig.IS_NEW_ARCHITECTURE_ENABLED
            override val isHermesEnabled: Boolean = BuildConfig.IS_HERMES_ENABLED
        }

    override val reactHost: ReactHost
        get() = AirborneReactNativeHost.getReactHost(applicationContext, reactNativeHost)

    override fun onCreate() {
        super.onCreate()

        // Initialize Airborne
        try {
            airborne = Airborne(
                this.applicationContext,
                "https://airborne.sandbox.juspay.in/release/airborne-react-example/android",
                object : AirborneInterface() {

                    override fun getNamespace(): String {
                        return "airborne-example" // Your app id
                    }

                    override fun getDimensions(): HashMap<String, String> {
                        val map = HashMap<String, String>()
                        map.put("city", "bangalore")
                        return map
                    }

                    override fun getLazyDownloadCallback(): LazyDownloadCallback {
                        return object : LazyDownloadCallback {
                            override fun fileInstalled(filePath: String, success: Boolean) {
                                // Logic
                            }

                            override fun lazySplitsInstalled(success: Boolean) {
                                // Logic
                            }
                        }
                    }

                    override fun onEvent(
                        level: String,
                        label: String,
                        key: String,
                        value: JSONObject,
                        category: String,
                        subCategory: String
                    ) {
                        // Log the event
                    }

                    override fun startApp(indexPath: String) {
                        isBootComplete = true
                        bundlePath = indexPath
                        bootCompleteListener?.invoke()
                    }
                })
            Log.i("Airborne", "Airborne initialized successfully")
        } catch (e: Exception) {
            Log.e("Airborne", "Failed to initialize Airborne", e)
        }

        SoLoader.init(this, OpenSourceMergedSoMapping)
    }
}

```

### 3. Use AirborneReactActivityDelegate in MainActivity
Return instance of AirborneReactActivityDelegate in the createReactActivityDelegate function.

```kotlin
import `in`.juspay.airborneplugin.AirborneReactActivityDelegate

class MainActivity : ReactActivity() {

  /**
   * Returns the name of the main component registered from JavaScript. This is used to schedule
   * rendering of the component.
   */
  override fun getMainComponentName(): String = "AirborneExample"

  /**
   * Returns the instance of the [ReactActivityDelegate]. We use [DefaultReactActivityDelegate]
   * which allows you to enable New Architecture with a single boolean flags [fabricEnabled]
   */
  override fun createReactActivityDelegate(): ReactActivityDelegate =
      AirborneReactActivityDelegate(this, mainComponentName, fabricEnabled)
}
```

### Note: If your app has a native SplashActivity.
If your app has a native `SplashActivity` before the `ReactActivity(MainActivity)` then you can listen to the `startApp` callback from the `AirborneInterface` to start the `ReactActivity`, In this case you have to listen to the `startApp` function from the `MainApplication` and start the `MainActivity` as shown in the below code snippet.
Note that this step is applicable only if your has a splash activity in native.
```kotlin
class SplashActivity : AppCompatActivity() {
    var hasBootCompleted = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.splash_screen)

        if (applicationContext is MainApplication) {
            (applicationContext as MainApplication).bootCompleteListener = {
                startMainActivity()
            }
            if ((applicationContext as MainApplication).isBootComplete) {
                startMainActivity()
            }
        }
    }

    private fun startMainActivity() {
        synchronized(this) {
            if (hasBootCompleted) return
            hasBootCompleted = true
        }
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }
}

```

## iOS Setup

### 1. Initialize Airborne in AppDelegate

In your `AppDelegate.swift`, initialize Airborne:

```swift
import UIKit
import Airborne

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    private var airborne: AirborneServices?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Initialize Airborne
        airborne = Airborne(releaseConfigURL: "https://yourdomain.com/release-config-url.json", delegate: self)
        
        return true
    }
}

// AirborneDelegate
extension AppDelegate: AirborneDelegate {
    func namespace() -> String {
        return "airborne-example"
    }
    
    func dimensions() -> [String : String] {
        ["city": "bangalore"]
    }
    
    func onLazyPackageDownloadComplete(downloadSuccess: Bool, url: String, filePath: String) {
        
    }
    
    func onAllLazyPackageDownloadsComplete() {
        
    }
    
    func onEvent(level: String, label: String, key: String, value: [String : Any], category: String, subcategory: String) {
        // Log the event
    }
    
    func startApp(indexBundleURL: URL?) {
        // Local file path URL for the available index bundle
    }
}
```

### 2. Wire silent-push background bundle download (iOS)

iOS supports the same silent-push-triggered background bundle download as Android. When the
backend sends an APNs silent push with `notification_type` (or `aps.category`) equal to
`UPDATE_AVAILABLE`, the SDK kicks off a `URLSession.background` download outside the app
process. The new bundle becomes live on the next user-initiated cold launch.

The push is delivered to the AppDelegate, not to JS, so wiring is done in native code
(mirrors the Android FCM service pattern). Forward two AppDelegate callbacks to Airborne:

```swift
import UIKit
import Airborne

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    // ... existing didFinishLaunchingWithOptions and Airborne init ...

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if AirborneServices.handleSilentPush(userInfo: userInfo,
                                              fetchCompletionHandler: completionHandler) {
            return
        }
        // Fall through to other push handlers (FCM, in-house, etc.)
        completionHandler(.noData)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if AirborneServices.handleBackgroundURLSession(identifier: identifier,
                                                        completionHandler: completionHandler) {
            return
        }
        // Fall through for other background URLSessions
        completionHandler()
    }
}
```

Both static methods return `true` if Airborne took ownership of the call. The consumer is
expected to fall through to other handlers when `false` is returned.

#### Capability checklist

| Requirement | Where | Notes |
| --- | --- | --- |
| `UIBackgroundModes` includes `remote-notification` | App `Info.plist` | Required so APNs `content-available: 1` wakes the app while suspended/terminated. |
| `aps-environment` entitlement (`development` or `production`) | App `*.entitlements` | Required for any push. |
| APNs auth key (.p8) configured on backend | Backend infra | Required to deliver pushes. |

`fetch` and `processing` background modes are NOT required — `URLSession.background` runs in
an OS-managed daemon that doesn't depend on those flags. `BGTaskScheduler` is not used.

#### Push payload contract

The SDK accepts either of these payload shapes (matches the existing NammaYatri convention):

```jsonc
// Form A — top-level notification_type (matches FCM data shape)
{ "aps": { "content-available": 1 }, "notification_type": "UPDATE_AVAILABLE" }

// Form B — aps.category (iOS standard category convention)
{ "aps": { "content-available": 1, "category": "UPDATE_AVAILABLE" } }
```

The payload does NOT need to carry the namespace; the SDK uses the namespace it was
initialized with via `AirborneServices.init(...)`. Multi-namespace consumer apps (rare) can
use the per-instance `airborne.handleSilentPush(...)` method to route explicitly.

Optional `entity_data` (JSON-encoded string) may carry `version` for logging; the SDK
ignores other fields.

#### Caveats

- **Force-quit apps**: APNs does not deliver silent pushes to apps the user has force-quit
  from the app switcher. Such users will fall back to the existing on-app-open download path.
- **APNs throttling**: silent pushes are best-effort; not every push is delivered. Treat as
  a faster bundle adoption path, not a guaranteed delivery channel.
- **No in-process reload**: when the background download finishes, the bundle is staged in
  `~/Library/JuspayManifests/<namespace>/app-pkg-temp.dat`. The next user-initiated cold
  launch swaps it in via the existing init path. The SDK does NOT force-restart the app.

#### iOS JS bridges

| JS method | iOS behavior |
| --- | --- |
| `checkForUpdate(namespace)` | Fetches RC + diffs against the on-disk bundle. Resolves with `"UPDATE_AVAILABLE"` / `"NO_UPDATE_AVAILABLE"` / error string. No download. |
| `downloadUpdate(namespace)` | Foreground download cycle (default `URLSession`). Resolves `true` once temp markers are written; the new bundle becomes live on the next user-initiated cold launch. |
| `startBackgroundDownload(namespace)` | Rejects with `AIRBORNE_NOT_IMPLEMENTED_IOS`. Silent-push handling on iOS is wired via the AppDelegate forwarder above; consumers don't trigger it from JS. |
| `hasPendingBundleUpdate(namespace)` | Rejects with `AIRBORNE_NOT_IMPLEMENTED_IOS`. The Android equivalent works around an OEM issue (some devices keep the JS context alive across "kill from recents"); iOS doesn't have that problem — the swap happens automatically on the next cold launch. |
| `reloadApp(namespace)` | Rejects with `AIRBORNE_NOT_IMPLEMENTED_IOS`. App Store guideline 4.5.4 discourages programmatic termination, and on iOS it's not needed: when the user closes/reopens the app naturally, `handleTempPackageInstallation` swaps in the new bundle. |

The `enableBootDownload` flag on `AirborneDelegate` (default `true`) gates the SDK's
automatic boot-time RC fetch + download. Setting it to `false` is the typical pairing
with the JS-driven `checkForUpdate` / `downloadUpdate` flow: the SDK serves the
already-committed bundle at boot and updates only when JS asks.

## React Native Usage

After native initialization, you can use Airborne in your React Native code:

```typescript
import { readReleaseConfig, getFileContent, getBundlePath } from 'airborne-react-native';

// Read release configuration
const config = await readReleaseConfig(namespace/appId);
console.log('Release config:', JSON.parse(config));

// Get file content from OTA bundle
const content = await getFileContent(namespace/appId, 'path/to/file.json');
console.log('File content:', content);

// Get bundle path
const bundlePath = await getBundlePath(namespace/appId);
console.log('Bundle path:', bundlePath);
```

## Architecture Compatibility

This implementation is compatible with both:

1. **Old Architecture**: Uses the traditional React Native bridge
2. **New Architecture (TurboModules)**: Uses the new TurboModule system with JSI

The module automatically detects which architecture is being used and loads the appropriate implementation.

## Error Handling

All methods return promises that can be rejected with error codes:

- `AIRBORNE_ERROR`: General Airborne errors
- `HYPER_OTA_NOT_INIT`: Airborne is not initialized (shouldn't happen if initialized in native code)

```typescript
try {
    const config = await readReleaseConfig(namespace/appId);
    // Use config
} catch (error) {
    console.error('Failed to read config:', error.message);
}
```

## Important Notes

1. **Native Instance**: The Airborne instance should be created and managed in native code. React Native only accesses this instance, it doesn't create its own.

2. **Thread Safety**: The implementation is thread-safe on both platforms.

3. **Callbacks**: The lazy download and onEvent should be handled in native code. You can expose these to React Native if needed by adding event emitters.

## Troubleshooting

1. **Module not found**: Make sure you've rebuilt the app after adding the native code
2. **Airborne not initialized**: Ensure the initialization code runs before any React Native code tries to use the module
3. **Build errors**: Check that you've added the Airborne SDK dependencies correctly
4. **Compatibility**: Please use node 20, java 17 to run the example apps.

## Future Enhancements

1. Handle the actual callbacks and events from the SDK
2. Add more methods as needed for your use case
