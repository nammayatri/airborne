# Integration Guide — After Publishing

Run the **Publish SDK** GitHub Actions workflow (Actions tab → Publish SDK → Run workflow).

The `rn-dist` branch is **always rebuilt every run** — `rn_version` is required. The two SDK publishes are opt-in via checkboxes:

| Input | What happens | Where |
|---|---|---|
| `publish_android` + `android_version` | (optional) Publish `com.movingtech:airborne:<X>` | Maven Central |
| `publish_ios` + `ios_version` | (optional) Publish `Airborne <Y>` pod + xcframework zip | `nammayatri/ny-cocoapods-specs` (podspec) + GitHub Release on this fork (binary) |
| `rn_version` | (always) Rebuild airborne-react-native at version `<Z>` with built `lib/` | `rn-dist` branch on this fork |

Versions are independent — Android, iOS, and RN tracks have unrelated version sequences.

---

## Build order — dependency chain

The RN plugin is the consumer of both SDKs:
- `airborne-react-native/android/build.gradle` declares `api "com.movingtech:airborne:<X>"`
- `airborne-react-native/AirborneReact.podspec` declares `s.dependency "Airborne", "<Y>"`

So when an app eventually installs `airborne-react-native` from the `rn-dist` branch, Gradle/CocoaPods will resolve those exact SDK coordinates. **The SDKs must already exist at those coordinates by the time the consumer installs**, otherwise `pod install` / `./gradlew assemble` fails with "could not resolve com.movingtech:airborne:...".

This dictates the run order. The workflow handles it for you in two ways:

### How a run sequences

1. **`publish-android` + `publish-ios`** (parallel) — run only if their checkboxes are ticked.
2. **`publish-rn-dist`** waits for both SDK jobs to finish. If either failed, rn-dist is skipped (so the branch never points at a non-existent SDK). If both succeeded (or were skipped because you left them unchecked), rn-dist proceeds.
3. The rn-dist job **uses `android_version` and `ios_version` (when supplied) to repoint** the RN plugin's Android `build.gradle` dep and `AirborneReact.podspec` dep before building. When either is left blank, whatever's currently committed for that platform is preserved.

### Common scenarios

| Scenario | Tick | Fill |
|---|---|---|
| Full release (new Android + iOS + RN) | `publish_android`, `publish_ios` | `android_version`, `ios_version`, `rn_version` |
| Android SDK patch | `publish_android` | `android_version`, `rn_version` (leave `ios_version` blank) |
| iOS SDK patch | `publish_ios` | `ios_version`, `rn_version` (leave `android_version` blank) |
| RN-only bump (TS or native) | (neither) | `rn_version` only |

### Anti-pattern — don't bake an SDK version into rn-dist that you haven't published

If you fill in `android_version` without ticking `publish_android` (and the version isn't already on Maven Central), the rn-dist branch will reference a coordinate that can't resolve. Consumer's `./gradlew assemble` will fail. The workflow doesn't validate this — your responsibility.

---

## Consumer app changes (`ny-react-native/consumer`)

### 1. RN plugin → point at the `rn-dist` branch

`consumer/package.json` (around line 91):

```diff
-  "airborne-react-native": "https://github.com/nammayatri/airborne/raw/test-artifacts/rn/airborne-react-native-0.33.0-xota.test.tgz",
+  "airborne-react-native": "github:<NY-fork-org>/airborne#rn-dist",
```

Then:
```bash
cd consumer
yarn install
```

To pick up a newer `rn-dist` push later, run `yarn upgrade airborne-react-native` — yarn 1 hash-pins git deps in `yarn.lock`, so a plain `yarn install` won't refresh on its own.

> If the airborne fork is private, `yarn install` needs HTTPS auth. Two options:
> - Set up a global git credential helper that caches a GitHub PAT, OR
> - Use the SSH form `git+ssh://git@github.com/<NY-fork-org>/airborne.git#rn-dist` and rely on developers' SSH keys.

### 2. iOS — add the NY CocoaPods spec repo to the Podfile

`consumer/ios/Podfile` — add the `nammayatri-specs` source **above** the trunk source so `Airborne` resolves from NY's repo:

```ruby
source 'https://github.com/nammayatri/ny-cocoapods-specs.git'
source 'https://cdn.cocoapods.org/'

# ... rest of Podfile unchanged
```

Keep the trunk source — every other pod still resolves from there.

Then on a developer machine that has access to `nammayatri-specs` (SSH key or PAT cached in keychain):

```bash
cd consumer/ios
pod repo add nammayatri-specs https://github.com/nammayatri/ny-cocoapods-specs.git  # one-time
pod install
```

`pod install` should resolve `Airborne <ios_version>` from `nammayatri-specs`, which downloads the xcframework zip from the GitHub Release URL baked into the podspec.

### 3. Android — verify Maven Central is in repos

`consumer/android/build.gradle` should already have `mavenCentral()` under `allprojects.repositories`. If it doesn't, add it:

```gradle
allprojects {
    repositories {
        google()
        mavenCentral()  // ← required for com.movingtech:airborne
        // ...
    }
}
```

If you previously added `mavenLocal()` for local-testing per `LOCAL_TESTING.md`, **remove it** before doing a release build — otherwise Gradle will silently prefer a stale local copy.

---

## Verify

### Android

```bash
cd consumer/android
./gradlew assembleNammaYatriProdRelease --refresh-dependencies
```

`--refresh-dependencies` forces Gradle to re-resolve `com.movingtech:airborne` from Maven Central instead of using a cached version.

### iOS

```bash
cd consumer/ios
pod install --clean-install   # nukes Pods/, re-resolves
xcodebuild -workspace Nammayatri.xcworkspace -scheme Cumta-Release \
  -configuration Release -destination 'generic/platform=iOS' build
```

If the iOS build fails with `'Airborne/AJPLoggerDelegate.h' file not found`, the xcframework patch step in the workflow didn't run — re-trigger the iOS publish and check the **Patch AJPLoggerDelegate.h into xcframework** step's output.

---

## Cheat sheet

| File | Change |
|---|---|
| `consumer/package.json` | `"airborne-react-native": "github:<NY-fork-org>/airborne#rn-dist"` |
| `consumer/ios/Podfile` | add `source 'https://github.com/nammayatri/ny-cocoapods-specs.git'` (one-time) |
| `consumer/android/build.gradle` | ensure `mavenCentral()` present, remove `mavenLocal()` if it's there from local-testing |

The workflow itself handles all the version bumps inside `airborne-react-native/` (package.json, podspec, build.gradle dep coordinate) before building — you don't need to commit those edits to `main`.