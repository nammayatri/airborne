# Local Testing Guide — Airborne OTA Changes

This guide explains how to test Airborne SDK and RN plugin changes locally against the consumer app (`ny-react-native/consumer`), without publishing to Maven Central or npm.

## Prerequisites

- Both repos cloned side by side:
  ```
  NammaYatri/
    airborne/              ← Airborne SDK + RN plugin
    ny-react-native/
      consumer/            ← Consumer app
  ```
- The consumer app has `airborne-react-native` symlinked:
  ```bash
  ls -la ny-react-native/consumer/node_modules/airborne-react-native
  # Should point to → ../../airborne/airborne-react-native
  ```

## Setup (one-time)

### 1. Symlink the RN plugin

If not already symlinked:

```bash
cd ny-react-native/consumer/node_modules
rm -rf airborne-react-native
ln -s ../../../airborne/airborne-react-native airborne-react-native
```

### 2. Consumer: Add Metro config for symlink resolution

In `consumer/metro.config.js`, add these two entries (do NOT commit):

```js
// Inside resolver.extraNodeModules:
'airborne-react-native': path.resolve(__dirname, '../../airborne/airborne-react-native'),

// Inside watchFolders array:
path.resolve(__dirname, '../../airborne/airborne-react-native'),
```

### 3. Consumer: Add mavenLocal to Gradle repos

In `consumer/android/build.gradle`, add `mavenLocal()` as the first repo (do NOT commit):

```gradle
allprojects {
    repositories {
        mavenLocal()  // ← Add this
        google()
        mavenCentral()
        // ...
    }
}
```

## Making Changes

### If you only changed RN plugin code (Kotlin/TS in `airborne-react-native/`)

The symlink handles this automatically. Just:

1. **For TypeScript changes** — rebuild the JS output:
   ```bash
   cd airborne/airborne-react-native
   npx bob build
   ```

2. **For Kotlin changes** — no extra step needed, Gradle picks them up from the symlinked source.

3. Rebuild the consumer app.

### If you changed SDK code (`airborne_sdk_android/`)

The RN plugin depends on the SDK via Maven artifact (`in.juspay:airborne:X.X.X`). Local SDK changes need to be published to mavenLocal:

1. **Temporarily change the SDK's groupId** (do NOT commit):

   In `airborne_sdk_android/airborne/build.gradle`, change:
   ```gradle
   groupId = 'io.juspay'    // ← original
   ```
   to:
   ```gradle
   groupId = 'in.juspay'    // ← matches the dependency
   ```

2. **Publish to mavenLocal**:
   ```bash
   cd airborne/airborne_sdk_android
   VERSION=2.2.7-xota.02-local ./gradlew :airborne:publishToMavenLocal
   ```

3. **Point the RN plugin to the local artifact** (do NOT commit):

   In `airborne-react-native/android/build.gradle`, change:
   ```gradle
   api "in.juspay:airborne:2.2.7-xota.02"          // ← original
   ```
   to:
   ```gradle
   api "in.juspay:airborne:2.2.7-xota.02-local"    // ← local build
   ```

4. Rebuild the consumer app.

### After making more SDK changes

Re-run the publish command — Gradle only recompiles changed files:

```bash
cd airborne/airborne_sdk_android
VERSION=2.2.7-xota.02-local ./gradlew :airborne:publishToMavenLocal
```

Then rebuild the consumer app. No need to change version strings again.

## Building the Consumer App

```bash
cd ny-react-native/consumer/android
./gradlew assembleNammaYatriProdRelease
```

Install the APK:
```bash
adb install -r app/build/outputs/apk/nammaYatri/prod/release/app-nammaYatri-prod-release.apk
```

## Debugging

Watch Airborne logs:
```bash
adb logcat -s Airborne ApplicationManager UpdateTask
```

## Before Committing

Make sure these files are **NOT committed** (they are local-testing-only changes):

| File | Local change | Why |
|------|-------------|-----|
| `airborne-react-native/android/build.gradle` | SDK version → `-local` | Points to local Maven artifact |
| `airborne_sdk_android/airborne/build.gradle` | groupId → `in.juspay` | Matches the dependency groupId |
| `consumer/android/build.gradle` | Added `mavenLocal()` | Enables local Maven resolution |
| `consumer/metro.config.js` | Added airborne to `extraNodeModules` + `watchFolders` | Enables Metro symlink resolution |

To check: `git diff --name-only` in both repos should only show these files as unstaged.

## Reverting Local Testing Changes

```bash
# In airborne repo
cd airborne
git checkout airborne-react-native/android/build.gradle
git checkout airborne_sdk_android/airborne/build.gradle

# In consumer repo
cd ny-react-native
git checkout consumer/android/build.gradle
git checkout consumer/metro.config.js
```

---

# iOS Local Testing

The iOS setup has two layers with different dependency mechanisms:

| Layer | Pod name | How it's consumed | Source location |
|-------|----------|-------------------|----------------|
| **RN plugin** | `AirborneReact` | Local path via node_modules symlink | `airborne/airborne-react-native/ios/` |
| **iOS SDK** | `Airborne` | Pre-built **xcframework** via CocoaPods | `airborne/airborne_sdk_iOS/hyper-ota/` |

The SDK is vendored as a binary xcframework — you can't just point Pods at source. The local-test loop for SDK changes is: **rebuild the xcframework → copy it into `Pods/Airborne/` → patch one missing header → build the app. Don't run `pod install` afterwards** (it'll restore the published xcframework and lose your changes).

## Setup (one-time)

### 1. Install Ruby gems

```bash
cd ny-react-native/consumer/ios
bundle install
```

### 2. Symlink the RN plugin

Consumer's `node_modules/airborne-react-native` → the sibling SDK repo:

```bash
cd ny-react-native/consumer/node_modules
rm -rf airborne-react-native
ln -s ../../../airborne/airborne-react-native airborne-react-native
```

Verify:
```bash
ls -la ny-react-native/consumer/node_modules/airborne-react-native
# → airborne-react-native -> ../../../airborne/airborne-react-native
```

### 3. Fetch the bundled release_config.json

The iOS SDK reads `release_config.json` from `Bundle.main` on first launch (before any OTA has landed) to know what to fetch. Grab the current one for your test namespace:

```bash
# For Cumta debug:
curl -s "https://airborne.juspay.in/release/movingtech/chennai-one-debug-ios" \
  -o ny-react-native/consumer/ios/release_config.json

# For other variants, swap the namespace (last path segment):
# curl -s "https://airborne.juspay.in/release/movingtech/<namespace>" \
#   -o ny-react-native/consumer/ios/release_config.json
```

Namespace comes from the app's `ota_base_url` in Info.plist.

### 4. Pre-generate `main.jsbundle` (only if you're testing in Debug)

Release builds auto-generate `main.jsbundle` via the `Bundle React Native code and images` Xcode build phase. Debug builds skip that phase, so without a pre-bundled file the app has nothing to load on first launch before the first OTA downloads.

Generate one manually at the path Cumta's target references:

```bash
cd ny-react-native/consumer
ENVFILE=./env/.env.development npx react-native bundle \
  --entry-file index.js \
  --platform ios \
  --dev false \
  --bundle-output ios/Cumta/Assets/main.jsbundle \
  --assets-dest ios/Cumta/Assets
```

For a different variant, swap the output path to match that variant's Assets folder (e.g. `ios/NammaYatri/Assets/main.jsbundle`).

Skip this step entirely if you're using a `-Release` scheme — Xcode bundles it for you.

### 5. (Optional) Load the Airborne bundle even in Debug

By default `AppDelegate.mm` routes Debug builds to the Metro dev server. If you want Debug to behave like Release (load the Airborne-installed bundle, fall through to `main.jsbundle`), edit `consumer/ios/Nammayatri/AppDelegate.mm`'s `bundleURL` method: remove the `#if DEBUG` branch so the Airborne path runs for both configurations. **Don't commit this change** — revert before pushing.

### 6. (Required for JS-driven update flow) Disable boot download in AppDelegate

If you want the consumer to pair with the JS-driven `checkForUpdate` / `downloadUpdate` flow rather than the SDK's automatic boot-time RC fetch, add an `enableBootDownload` method to `consumer/ios/Nammayatri/AppDelegate.mm`'s `AirborneDelegate` conformance:

```objc
- (BOOL)enableBootDownload {
  return NO;
}
```

This is paired with `enableBootDownload() = false` on the Android consumer's `AirborneInterface`. JS code is then responsible for calling `checkForUpdate` and `downloadUpdate` at appropriate times; on success, the new bundle becomes live on the next user-initiated cold launch via the SDK's existing `handleTempPackageInstallation` path. This change IS meant for commit — it's the consumer's intended runtime configuration, not a local-test toggle.

### 7. Pod state sanity (one-time)

Before swapping the local xcframework, make sure `Pods/Manifest.lock` matches `Podfile.lock`:

```bash
diff consumer/ios/Podfile.lock consumer/ios/Pods/Manifest.lock
```

If they differ, builds fail at the `Check Pods Manifest.lock` script phase before reaching any source compile. Run `pod install` (or `bundle exec pod install` if your Gemfile is in good shape) once to sync, **then** swap the xcframework. Don't run `pod install` again after — it'll restore the published Airborne pod and discard the swap.

If `pod install` complains about an unrelated dependency conflict (e.g. mismatched `AppMonitor` versions between `Podfile.lock` and a local `react-native-app-monitor`), that's a consumer-side issue independent of Airborne — resolve it (typically `pod update <name>` or `pod install --repo-update`) before retrying.

## If you only changed RN plugin code (`airborne-react-native/ios/`)

The symlink picks up changes automatically. Rebuild the consumer app. No `pod install` needed unless you added/removed files.

## If you changed iOS SDK code (`airborne_sdk_iOS/`)

### Build the local xcframework

```bash
cd airborne/airborne_sdk_iOS/hyper-ota

rm -rf /tmp/airborne-build
xcodebuild -project Airborne.xcodeproj \
  -scheme AirborneAggregate \
  -configuration Release \
  -derivedDataPath /tmp/airborne-build \
  -quiet
```

Output lands at `/tmp/airborne-build/Build/Products/Airborne.xcframework`. The `AirborneAggregate` scheme has a built-in Run Script phase that calls `xcodebuild -create-xcframework` — no manual archive/lipo needed.

Sanity-check the build succeeded:
```bash
ls /tmp/airborne-build/Build/Products/Airborne.xcframework
# Should list: Info.plist, ios-arm64, ios-arm64_x86_64-simulator
```

### Swap into the consumer app's Pods

```bash
PODS_AIRBORNE=/Users/<you>/Documents/NammaYatri/ny-react-native/consumer/ios/Pods/Airborne

rm -rf "$PODS_AIRBORNE/Airborne.xcframework"
cp -R /tmp/airborne-build/Build/Products/Airborne.xcframework "$PODS_AIRBORNE/"
```

### Remove the dead `AJPLoggerDelegate` import in the RN plugin

`airborne-react-native/ios/AirborneReact.mm` has `#import <Airborne/AJPLoggerDelegate.h>` near the top. Nothing in that file references the symbol — it's a dead import. With a locally-built xcframework it breaks the RN plugin compile because the source tree doesn't ship `AJPLoggerDelegate.h` (see next step). Delete the line:

```objc
#import <Airborne/AJPLoggerDelegate.h>   // ← remove this
```

Do NOT commit. Revert before pushing.

### Patch the missing header

The SDK source tree is missing an ObjC header (`AJPLoggerDelegate.h`) that the published CocoaPods artifact includes — the SDK team's publish pipeline adds it before packaging but the source repo doesn't reproduce that. If you skip this step you'll get `'Airborne/AJPLoggerDelegate.h' file not found` in the consumer build.

Copy it from the CocoaPods cache (where the published 0.30.1 pod is stashed):

```bash
PUB=~/Library/Caches/CocoaPods/Pods/Release/Airborne/0.30.1-75d28/Airborne.xcframework
LOCAL="$PODS_AIRBORNE/Airborne.xcframework"

cp "$PUB/ios-arm64/Airborne.framework/Headers/AJPLoggerDelegate.h" \
   "$LOCAL/ios-arm64/Airborne.framework/Headers/"
cp "$PUB/ios-arm64_x86_64-simulator/Airborne.framework/Headers/AJPLoggerDelegate.h" \
   "$LOCAL/ios-arm64_x86_64-simulator/Airborne.framework/Headers/"
```

If the cached path doesn't exist on your machine, any recent consumer `pod install` will populate it. Or grab the file from any teammate's CocoaPods cache.

### After further SDK changes

Re-run the build + swap + header-copy block. Each edit to `airborne_sdk_iOS/` needs all three steps:

```bash
(cd airborne/airborne_sdk_iOS/hyper-ota && \
   rm -rf /tmp/airborne-build && \
   xcodebuild -project Airborne.xcodeproj -scheme AirborneAggregate \
     -configuration Release -derivedDataPath /tmp/airborne-build -quiet) && \
PODS_AIRBORNE=/Users/<you>/Documents/NammaYatri/ny-react-native/consumer/ios/Pods/Airborne && \
rm -rf "$PODS_AIRBORNE/Airborne.xcframework" && \
cp -R /tmp/airborne-build/Build/Products/Airborne.xcframework "$PODS_AIRBORNE/" && \
PUB=~/Library/Caches/CocoaPods/Pods/Release/Airborne/0.30.1-75d28/Airborne.xcframework && \
cp "$PUB/ios-arm64/Airborne.framework/Headers/AJPLoggerDelegate.h" \
   "$PODS_AIRBORNE/Airborne.xcframework/ios-arm64/Airborne.framework/Headers/" && \
cp "$PUB/ios-arm64_x86_64-simulator/Airborne.framework/Headers/AJPLoggerDelegate.h" \
   "$PODS_AIRBORNE/Airborne.xcframework/ios-arm64_x86_64-simulator/Airborne.framework/Headers/"
```

### ⚠️ Do NOT run `pod install` after swapping

CocoaPods will fetch the published pod and overwrite your local xcframework. If you do run it (accidentally, or to add an unrelated pod), re-run the build + swap + header-copy block above.

## Building the Consumer iOS App

### List available schemes

```bash
cd ny-react-native/consumer/ios
xcodebuild -workspace Nammayatri.xcworkspace -list 2>&1 | grep -E "Debug|Release"
```

Common: `Cumta-Debug`, `Cumta-Release`, `NammaYatri-Debug`, `NammaYatri-Release`, `Bridge-Debug`, `Bridge-Release`.

### Build for simulator (command line)

```bash
cd ny-react-native/consumer/ios

# List simulators
xcrun simctl list devices available | grep iPhone

# Cumta-Debug on iPhone 16 simulator
xcodebuild -workspace Nammayatri.xcworkspace \
  -scheme Cumta-Debug \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build \
  build
```

### Install + launch

```bash
xcrun simctl boot "iPhone 16" 2>/dev/null; open -a Simulator
APP_PATH=$(find build -name "*.app" -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted $(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")
```

### Build from Xcode (alternative)

1. Open `consumer/ios/Nammayatri.xcworkspace`.
2. Select a scheme (`Cumta-Debug` or `Cumta-Release`).
3. Pick a simulator.
4. **Cmd + R** to build and run.

### Fixing stale Xcode build errors

If the consumer app fails with errors that no longer match the current source (e.g. `'Airborne/AJPLoggerDelegate.h' file not found` persists after you've patched the header in), Xcode is using a cached precompiled-headers state. Clear it:

1. In Xcode: **Product → Clean Build Folder** (Shift + Cmd + K), then **Cmd + B**.
2. If that doesn't work, quit Xcode completely, then:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/Nammayatri-*
   ```
3. Reopen the workspace and rebuild.

## Debugging iOS

The SDK uses `NSLog`, so logs appear in the Xcode console automatically. Filter by `Airborne` in the console search bar, or stream from terminal:

```bash
xcrun simctl spawn booted log stream \
  --predicate 'processImagePath contains "Cumta" OR processImagePath contains "Nammayatri"' \
  | grep -i airborne
```

The background-download coordinator additionally writes structured events under the
`in.juspay.Airborne` `BackgroundDownload` `os_log` subsystem. Stream those specifically:

```bash
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "in.juspay.Airborne" AND category == "BackgroundDownload"'
```

## Verifying the JS-driven update flow

End-to-end recipe to confirm `enableBootDownload = false` + JS `checkForUpdate` / `downloadUpdate` works against your local SDK:

1. **Confirm the boot path is suppressed.** Launch the app cold. In the Airborne logs you should see `boot_download_disabled` and no `release_config_fetch` event from the SDK. If the SDK still fetches at boot, the consumer hasn't picked up the `enableBootDownload` delegate method (re-check step 6 in setup).

2. **Trigger a check from JS.** Once the bridge is up, call from JS or the React Native console:

   ```js
   import { checkForUpdate, downloadUpdate } from 'airborne-react-native';

   const status = await checkForUpdate('<your-namespace>');
   console.log('checkForUpdate →', status);
   ```

   Expected values:
   - `"UPDATE_AVAILABLE"` — server has a newer bundle than what's on disk.
   - `"NO_UPDATE_AVAILABLE"` — already up to date.
   - `"NO_PERSISTED_CONFIG"` — the SDK was never initialized for this namespace in this process; usually means `airborneInstance` wasn't built in `AppDelegate`.
   - any other string — the underlying error message.

3. **Trigger a download.**

   ```js
   const ok = await downloadUpdate('<your-namespace>');
   console.log('downloadUpdate →', ok);
   ```

   When `ok === true`, the SDK has staged the new bundle. Verify the temp markers exist on disk via the simulator:

   ```bash
   SIM=$(xcrun simctl list devices booted | grep -E "Booted" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
   APP=$(xcrun simctl get_app_container "$SIM" <your-bundle-id> data)
   ls "$APP/Library/JuspayManifests/<your-namespace>/"
   # Look for: app-pkg-temp.dat (and optionally app-resources-temp.dat)
   ```

4. **Restart cleanly.** Close the app from the app switcher, then reopen it. On launch the Airborne logs should show `temp_package_installation_started` and then `temp_package_installed` with the new package version. Calling `getReleaseConfig()` from JS afterwards reflects the new package version.

If step 4 shows no temp-package-installation event, either the temp file wasn't written (step 3 didn't actually succeed) or the next-launch init path isn't reading from it — re-check the Airborne logs from step 1 for which init branch the manager took.

## Before Committing (iOS)

These files / paths are **local-testing-only** — don't commit them:

| File | Local change | Why |
|------|-------------|-----|
| `consumer/ios/release_config.json` | Bundled release config for test namespace | Namespace-specific, not your app's |
| `airborne-react-native/ios/AirborneReact.mm` | Removed `#import <Airborne/AJPLoggerDelegate.h>` | Dead import; only needed to make a locally-built xcframework compile |
| `consumer/ios/Pods/Airborne/Airborne.xcframework` | Swapped local xcframework + patched AJPLoggerDelegate.h | Would overwrite the published pod reference |
| `consumer/ios/Cumta/Assets/main.jsbundle` (if hand-generated for Debug) | Pre-bundled JS with debug env | Release builds regenerate this automatically |
| `consumer/ios/Nammayatri/AppDelegate.mm` (if you removed `#if DEBUG`) | Airborne-first bundle resolution in Debug | Breaks Metro dev-server workflow for teammates |

The `enableBootDownload` method added to `consumer/ios/Nammayatri/AppDelegate.mm` (setup step 6) is the **exception** — that one IS meant for commit. It's the consumer's runtime configuration mirroring `enableBootDownload() = false` on the Android side.

Verify before pushing:
```bash
cd ny-react-native && git diff --name-only
```

## Reverting iOS local-testing changes

```bash
# In consumer repo — restore Metro + published pod
cd ny-react-native
rm -f consumer/ios/release_config.json
git checkout -- consumer/ios/Nammayatri/AppDelegate.mm         # if you edited it
cd consumer/ios && bundle exec pod install                     # restores published Airborne.xcframework
```
