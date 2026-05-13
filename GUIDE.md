# Airborne - Complete Project Guide

> A comprehensive OTA (Over-The-Air) update platform for Android, iOS, and React Native apps. Built as a replacement for Microsoft CodePush.

---

## Table of Contents

1. [What is Airborne?](#what-is-airborne)
2. [Architecture Overview](#architecture-overview)
3. [Components](#components)
4. [The Complete Flow: Upload to Device](#the-complete-flow-upload-to-device)
5. [React Native Plugin Deep Dive](#react-native-plugin-deep-dive)
6. [Server Architecture](#server-architecture)
7. [CLI Tools](#cli-tools)
8. [Dashboard](#dashboard)
9. [Analytics](#analytics)
10. [Key Concepts](#key-concepts)
11. [Features](#features)
12. [Limitations](#limitations)
13. [Infrastructure & Deployment](#infrastructure--deployment)

---

## What is Airborne?

Airborne is a self-hosted OTA update platform that lets you push JavaScript bundle updates to React Native (and native Android/iOS) apps without going through app store review. It was built by Juspay as a replacement for Microsoft's CodePush, which was discontinued.

**Core idea**: Your app checks a server endpoint on launch. If a newer bundle exists, it downloads and applies it — all before the app finishes booting (or gracefully falls back to the previous version).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DEVELOPER WORKFLOW                           │
│                                                                     │
│  1. Build RN bundle    2. Upload files     3. Create package        │
│  (metro bundler)       (CLI → S3)          (CLI → Server)           │
│       ↓                     ↓                    ↓                  │
│  JS bundle + assets   File entries in DB   Package groups files     │
│                                                   ↓                 │
│                                            4. Create release        │
│                                            (Superposition experiment)│
│                                                   ↓                 │
│                                            5. Ramp traffic 0→100%   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        USER'S DEVICE                                │
│                                                                     │
│  App launches → Native Airborne SDK initializes                     │
│       ↓                                                             │
│  GET /release/{org}/{app}  (with dimensions header)                 │
│       ↓                                                             │
│  Server returns: config + file manifest (URLs, checksums)           │
│       ↓                                                             │
│  SDK compares versions → downloads new files if needed              │
│       ↓                                                             │
│  Important files within timeout? → Boot new bundle                  │
│  Timeout exceeded? → Fallback to previous bundle                    │
│       ↓                                                             │
│  Lazy files download in background                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Components

| Component | Location | Tech | Purpose |
|-----------|----------|------|---------|
| **Server** | `airborne_server/` | Rust, Actix-web, PostgreSQL, S3 | Backend API for managing releases, serving configs |
| **Analytics Server** | `airborne_analytics_server/` | Rust, Axum, Kafka, ClickHouse | OTA event tracking and adoption metrics |
| **React Native Plugin** | `airborne-react-native/` | TypeScript, Kotlin, Swift | Client SDK for RN apps |
| **Android SDK** | `airborne_sdk_android/` | Kotlin | Native Android OTA SDK |
| **iOS SDK** | `airborne_sdk_iOS/` | Swift/ObjC | Native iOS OTA SDK |
| **Dashboard** | `airborne_dashboard/` | Next.js 15, React 19 | Admin UI for managing everything |
| **DevKit CLI** | `airborne_cli/` | Node.js, Commander | Developer-facing CLI for RN projects |
| **Core CLI** | `airborne-core-cli/` | Node.js, Commander | Low-level CLI for server operations |
| **Server SDK** | `airborne_server_clients/` | TypeScript (Smithy-generated) | Typed client for the server API |
| **API Definitions** | `smithy/` | Smithy DSL | API contract (generates SDK clients) |

---

## The Complete Flow: Upload to Device

### Phase 1: Developer Uploads Bundle

```
Developer's Machine
────────────────────
1. Build the RN bundle:
   npx react-native bundle --platform android --entry-file index.js ...

2. Initialize project config:
   airborne-devkit create-local-airborne-config \
     --android-organisation myorg \
     --android-namespace myapp

3. Authenticate:
   airborne-devkit login --client_id xxx --client_secret yyy
   → POST /users/login → JWT token stored locally

4. Upload files to server:
   airborne-devkit create-remote-files -p android --upload
   → For each file:
     POST /file  (creates DB entry with file_path, version)
     PUT to S3   (uploads actual binary)
     Server calculates SHA256 checksum asynchronously
   → S3 path: assets/{org}/{app}/{file_id}/{version}/{filename}

5. Create a package (groups files into an atomic unit):
   airborne-devkit create-remote-package -p android
   → POST /packages
   → Links: index file + important files + lazy files
   → Auto-increments package version (1, 2, 3...)
```

### Phase 2: Create & Ramp a Release

```
Dashboard or CLI
─────────────────
6. Create a release:
   POST /releases
   Body: {
     config: { boot_timeout: 5000, release_config_timeout: 1000 },
     package_id: "version:3",
     dimensions: { platform: "android", min_version: "1.5" },
     important: ["index.js@version:3", "core.js@version:3"],
     lazy: ["animations.js@version:2"],
     resources: ["logo.png@version:1"]
   }

   What happens internally:
   → Server creates a Superposition EXPERIMENT with 2 variants:
     - Control:      current stable config (what users have now)
     - Experimental: new release config (what you're pushing)
   → Traffic starts at 0% (nobody gets the new version yet)

7. Ramp traffic gradually:
   POST /releases/{id}/ramp  { traffic_percentage: 10 }  → 10% get new version
   POST /releases/{id}/ramp  { traffic_percentage: 50 }  → 50%
   POST /releases/{id}/ramp  { traffic_percentage: 100 } → everyone

8. Conclude the release:
   POST /releases/{id}/conclude
   → Experimental variant becomes the new baseline
   → Old version is no longer served
```

### Phase 3: User's Device Gets the Update

```
User's Phone (App Launch)
──────────────────────────
9.  App starts → Native Airborne SDK initializes with:
    - Release config URL: https://airborne.example.com/release/{org}/{app}
    - Dimensions: { platform: "android", app_version: "1.5.2", ... }

10. SDK calls: GET /release/{org}/{app}
    Headers: x-dimension: platform=android;app_version=1.5.2

11. Server processes request:
    → Extracts dimensions from header
    → Generates a random "toss" (0-99) for this request
    → Calls Superposition: "Given these dimensions and toss, which variant?"
    → Superposition evaluates: if toss < traffic_percentage → experimental, else → control
    → Resolves the winning variant's config
    → Fetches file URLs and checksums from DB
    → Returns ServeReleaseResponse (cached via CloudFront, s-maxage=86400)

12. Response looks like:
    {
      "version": "2",
      "config": {
        "boot_timeout": 5000,
        "version": "uuid-of-this-config",
        "properties": { ... }
      },
      "package": {
        "name": "myapp",
        "version": "3",
        "index": { "file_path": "index.js", "url": "https://cdn.../index.js", "checksum": "sha256..." },
        "important": [ { "file_path": "core.js", "url": "...", "checksum": "..." } ],
        "lazy": [ { "file_path": "animations.js", "url": "...", "checksum": "..." } ]
      },
      "resources": [ { "file_path": "logo.png", "url": "...", "checksum": "..." } ]
    }

13. SDK compares package version with what's currently installed

14. If new version → Download starts:

    ┌─────────────────── boot_timeout (e.g. 5 seconds) ───────────────┐
    │                                                                   │
    │  Download IMPORTANT files (index.js, core.js)                     │
    │  Download RESOURCES (logo.png) - best effort                      │
    │                                                                   │
    │  All important files done?                                        │
    │  ├─ YES → Boot with new bundle ✓                                  │
    │  └─ NO  → Discard everything, boot with previous bundle           │
    │                                                                   │
    └───────────────────────────────────────────────────────────────────┘

    After boot: Download LAZY files in background
    → Callback: fileInstalled(filePath, success) for each

15. App is now running with the updated JavaScript bundle.
```

---

## React Native Plugin Deep Dive

### Installation & Setup

The plugin is a Turbo Module (`airborne-react-native` on npm) supporting both old and new React Native architectures.

### JavaScript API

```typescript
import { readReleaseConfig, getFileContent, getBundlePath } from 'airborne-react-native';

// Get the release configuration (JSON string)
const config = await readReleaseConfig("my-namespace");

// Read content of a specific file from the OTA bundle
const content = await getFileContent("my-namespace", "some-module.js");

// Get the filesystem path to the current bundle
const bundlePath = await getBundlePath("my-namespace");
```

That's it - only 3 methods. The heavy lifting happens in native code.

### Android Native Layer

```
AirbornePackage.kt          → Registers the module with React Native
  ├─ AirborneTurboModule.kt → New Architecture (TurboModule/JSI)
  ├─ AirborneModule.kt      → Old Architecture (Bridge)
  └─ AirborneModuleImpl.kt  → Shared implementation (delegates to Airborne.kt)

Airborne.kt                 → Core orchestrator
  ├─ Initializes HyperOTAServices (core Android SDK)
  ├─ Creates ApplicationManager with dimensions
  ├─ getBundlePath()    → returns file path or asset fallback
  ├─ getFileContent()   → reads split/lazy files
  ├─ getReleaseConfig() → returns JSON config
  └─ setSslConfig()     → mTLS support

AirborneInterface.kt        → Extensibility hooks (abstract class)
  ├─ getNamespace()          → app identifier
  ├─ getDimensions()         → targeting attributes
  ├─ startApp(indexPath)     → callback when bundle is ready
  ├─ onEvent(...)            → analytics/logging callback
  └─ getLazyDownloadCallback() → notified when lazy files arrive

AirborneReactActivityDelegate.kt → Manages activity lifecycle
  ├─ State machine: BEFORE_APPLOAD → APP_LOADED → ONRESUME_CALLED
  ├─ Waits for bundle update before calling loadApp()
  └─ Handles pause/resume/destroy properly

AirborneReactNativeHostBase.kt → Bundle loading
  ├─ Asset loader:  assets://index.android.bundle (fallback)
  └─ File loader:   /data/.../bundle_path (OTA bundle)
```

### iOS Native Layer

```
AirborneReact.mm (.h)       → React Native bridge (Objective-C++)
  ├─ New Arch: TurboModule/JSI (RCT_NEW_ARCH_ENABLED)
  ├─ Old Arch: RCT_EXPORT_METHOD bridge
  ├─ readReleaseConfig(resolve, reject)
  ├─ getFileContent(filePath, resolve, reject)
  ├─ getBundlePath(resolve, reject)
  └─ Class methods for initialization:
     +initializeAirborneWithReleaseConfigUrl:
     +initializeAirborneWithReleaseConfigUrl:inNamespace:
     +initializeAirborneWithReleaseConfigUrl:delegate:

Airborne.m (.h)             → Core OTA singleton manager
  ├─ Thread-safe singleton (dispatch_queue_t with read-write locking)
  ├─ getBundlePath()
  ├─ getFileContent(filePath)
  └─ getReleaseConfig()
```

### How Bundle Loading Works on App Start

**Android**:
1. `AirborneReactActivityDelegate` intercepts `loadApp()`
2. Checks if `AirborneReactNativeHost` has a new bundle
3. Waits for Airborne SDK to resolve the bundle (async)
4. If new bundle available → uses file path from OTA download
5. If not → falls back to `assets://index.android.bundle`
6. Calls `loadApp()` on the main thread with resolved bundle

**iOS**:
1. `AirborneReact.initializeAirborne(withReleaseConfigUrl:)` called in AppDelegate
2. Creates singleton `Airborne` instance
3. `bundleURL()` returns OTA path if available, else the compiled bundle
4. React Native loads from the returned URL

### Namespace Support

Airborne supports **multiple namespaces** in a single app binary. Each namespace is an independent OTA target with its own:
- Release config URL
- Dimensions
- Downloaded bundles
- Configuration

This enables apps that host multiple "mini-apps" to update them independently.

### Split Bundle Support

Files are categorized into three tiers:

| Category | Behavior | Use Case |
|----------|----------|----------|
| **Important** | Must download before boot timeout. All-or-nothing. | Core JS bundle, critical modules |
| **Lazy** | Download after boot in background. Callback on completion. | Feature modules, heavy animations |
| **Resources** | Best-effort before timeout. Whatever completes is used. | Images, fonts, data files |

---

## Server Architecture

### Tech Stack

- **Language**: Rust
- **Web Framework**: Actix-web 4
- **Database**: PostgreSQL (Diesel ORM)
- **Object Storage**: AWS S3 (LocalStack for dev)
- **CDN**: CloudFront
- **Auth**: Keycloak (OpenID Connect, JWT)
- **Config/Experiments**: Superposition SDK
- **Encryption**: AES-GCM with AWS KMS

### Data Model

```
Organisation (managed in Keycloak)
  └─ Application
       ├─ Files (individual versioned assets)
       │   └─ file_path, version, tag, url, checksum (SHA256), size, metadata
       ├─ Packages (atomic groups of files)
       │   └─ index file, file list, version, tag
       ├─ Releases (Superposition experiments)
       │   └─ control variant, experimental variant, traffic %, dimensions
       └─ Builds (pre-packaged ZIP/AAR artifacts)
           └─ semver version, S3 URL
```

### Key Endpoints

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `POST /file` | JWT | Upload a file entry |
| `POST /file/bulk` | JWT | Bulk upload files |
| `GET /file/list` | JWT | List files with pagination |
| `POST /packages` | JWT | Create a package from files |
| `GET /packages/list` | JWT | List packages |
| `POST /releases` | JWT | Create a release (experiment) |
| `POST /releases/{id}/ramp` | JWT | Change traffic percentage |
| `POST /releases/{id}/conclude` | JWT | Finalize rollout |
| `DELETE /releases/{id}` | JWT | Discard/rollback release |
| **`GET /release/{org}/{app}`** | **Public** | **Serve release config to clients** |
| `POST /users/login` | - | Authenticate, get JWT |
| `POST /organisations` | JWT | Create organization |
| `POST /organisation/application` | JWT | Create application |

### Superposition Integration

Superposition is the experimentation/feature-flag engine that powers releases:

- Each **release** = a Superposition **experiment** with 2 variants
- **Control**: current stable release config
- **Experimental**: the new release being rolled out
- **Ramping**: controls what % of traffic gets the experimental variant
- **Dimensions**: context attributes (platform, app version, region, etc.) that determine targeting
- **Resolution**: given a client's dimensions + a random toss value, Superposition decides which variant to serve

Default configs stored in `superposition-default-configs.json`:
- `config.version`, `config.boot_timeout` (1000ms default), `config.release_config_timeout` (1000ms default)
- `package.name`, `package.version`, `package.index`, `package.important`, `package.lazy`
- `resources`

### File Versioning

Files use a key format: `file_path@version:N` or `file_path@tag:name`
- Example: `index.js@version:3` or `index.js@tag:latest`
- Each upload increments the version number
- Tags (like "latest") are mutable pointers to a specific version

### Build Artifacts

The server can generate pre-packaged builds for native integration:
- **ZIP** (iOS): Contains `AirborneAssets/` with all files + `release_config.json`
- **AAR** (Android): Proper Android library with `assets/{org}/{app}/app/package/` structure + Maven metadata
- Versioned with semver, uploaded to S3

### Role-Based Access Control

| Role | Scope | Permissions |
|------|-------|-------------|
| Owner | Organization | Full control over org + all apps |
| Admin | Organization | Manage users, apps, releases |
| Admin | Application | Manage specific app's releases |
| Write | Application | Upload files, create packages/releases |
| Read | Application | View releases and configs |

### Transactional Integrity

Operations that span multiple systems (DB + S3 + Keycloak + Superposition) use a transaction manager with automatic rollback. A background cleanup job handles failed partial operations.

---

## CLI Tools

### airborne-devkit (Developer CLI)

Installed as `airborne-devkit` binary. This is what RN developers use day-to-day.

```bash
# Initialize project
airborne-devkit create-local-airborne-config [dir] \
  --android-organisation myorg \
  --ios-organisation myorg \
  --android-namespace my.app.android \
  --ios-namespace my.app.ios \
  -j index.js

# Create platform-specific release config
airborne-devkit create-local-release-config

# Upload bundle files to server
airborne-devkit create-remote-files -p android --upload

# Create a package from uploaded files
airborne-devkit create-remote-package -p android

# Update existing release config
airborne-devkit update-local-release-config
```

### airborne-core-cli (Low-level CLI)

Wraps the server SDK for direct API operations:

```bash
# Auth
airborne-core-cli PostLogin --client_id xxx --client_secret yyy

# Organization & app management
airborne-core-cli CreateOrganisation --name myorg
airborne-core-cli CreateApplication --name myapp

# File operations
airborne-core-cli CreateFile --file_path index.js --url https://...
airborne-core-cli ListFiles

# Package operations
airborne-core-cli CreatePackage --index "index.js@version:1" --files '["core.js@version:1"]'

# Release operations
airborne-core-cli CreateRelease @release-params.json
airborne-core-cli ListReleases
airborne-core-cli GetRelease --release_id xxx
```

Both CLIs accept input as individual flags OR as a JSON file (`@params.json`).

---

## Dashboard

A Next.js 15 web application (`airborne_dashboard/`) for visual management:

- **Release Management**: Create, view, ramp, conclude, discard releases
- **Package Management**: Upload and track bundles
- **File Management**: Browse uploaded files and versions
- **Organization & App Management**: Team collaboration
- **Dimension Management**: Configure targeting rules and A/B tests
- **Analytics Visualization**: Adoption charts and metrics (via Recharts)
- **Authentication**: Keycloak OIDC integration

---

## Analytics

The analytics server (`airborne_analytics_server/`) tracks OTA update lifecycle events:

### Tracked Events
- `update_started`, `update_downloading`, `update_downloaded`
- `update_installing`, `update_installed`, `update_failed`
- `update_cancelled`, `rollback_started`, `rollback_completed`

### Metrics Available
- Update adoption rates and trends
- Version distribution across devices
- Active device counts
- Failure rates and error analysis
- Download speeds and install times

### Two Backend Options
1. **Kafka + ClickHouse**: Event streaming → columnar OLAP database (high throughput)
2. **Grafana + Victoria Metrics**: Time-series database + dashboards (simpler setup)

---

## Key Concepts

### Dimensions
Key-value pairs that describe a client's context: `{ platform: "android", app_version: "2.1.0", region: "IN" }`. The server uses these to decide which release variant to serve. You define dimensions per application and can create targeting rules.

### Toss-based Traffic Splitting
Each client request gets a random number (0-99). If `toss < traffic_percentage`, the client gets the experimental variant (new release). Otherwise, it gets the control (current stable). This is how gradual rollouts work.

### Boot Timeout
The critical window (default 5s) during which the SDK must finish downloading important files. If the download doesn't complete in time, the entire update is discarded and the app boots with the previous working bundle. This ensures users never see a blank screen.

### Package Atomicity
A package is all-or-nothing for important files. Either all important files download successfully, or the entire package is rejected. This prevents partial/broken updates.

### Workspace
Each org+app combination maps to a Superposition "workspace" — an isolated configuration namespace. This is how multi-tenancy works at the config layer.

---

## Features

### What Airborne Supports

- **Multi-platform**: Android (native + RN), iOS (native + RN), React Native
- **Gradual rollouts**: Ramp from 0% to 100% with A/B testing
- **Dimension-based targeting**: Serve different releases based on platform, version, region, etc.
- **Split bundles**: Important (pre-boot), lazy (post-boot), resources (best-effort)
- **Automatic fallback**: Boot timeout ensures the app always loads
- **File integrity**: SHA256 checksums on all downloads
- **Multi-namespace**: Multiple independent OTA targets in one app
- **Self-hosted**: Full control over infrastructure and data
- **Multi-tenant**: Organizations with role-based access control
- **CDN caching**: CloudFront integration for fast global delivery
- **Pre-packaged builds**: Generate ZIP (iOS) and AAR (Android) artifacts
- **Both RN architectures**: Supports old bridge and new TurboModule/JSI
- **Analytics**: Track update lifecycle, adoption, failures
- **mTLS support**: Secure client-server communication
- **Smithy-generated SDK**: Type-safe client in TypeScript
- **Dashboard**: Full web UI for management
- **CLI tools**: Automate everything from the command line
- **Conventional versioning**: Automated semver with cocogitto

### What It Does NOT Support / Limitations

- **No delta/diff patching**: Downloads full files, not binary diffs. If a 2MB file changes 1 byte, the entire 2MB is re-downloaded. (CodePush had binary diff support.)
- **No client-side persistence of toss**: The toss is generated per-request, so the same device may flip between variants across requests (though CloudFront caching mitigates this for the cache TTL duration).
- **No automatic retry on failed downloads**: If important files fail to download within boot_timeout, the update is discarded. The SDK will try again on next app launch, but there's no built-in retry loop.
- **No background update checks**: Updates are only checked at app launch (when the SDK initializes). There's no periodic background polling.
- **Requires Superposition**: The server depends on Superposition for experiment/config management. This is a hard dependency, not optional.
- **Requires Keycloak**: Authentication is tightly coupled to Keycloak. You can't swap in a different auth provider without significant changes.
- **No Web support**: Only Android and iOS. No browser-based OTA.
- **No mandatory update enforcement**: The SDK doesn't have a built-in mechanism to force users to update or block app usage on old versions. This would need to be built in app logic using the config properties.
- **CloudFront cache staleness**: Release responses are cached with `s-maxage=86400` (24 hours). After ramping, users may get stale configs until cache expires or is manually invalidated.
- **No rollback button**: Discarding a release removes it, but there's no one-click "rollback to version X". You'd create a new release pointing to the old package.
- **PostgreSQL only**: No support for other databases.
- **S3 only**: No support for other object stores (GCS, Azure Blob) without code changes.

---

## Infrastructure & Deployment

### Required Services

| Service | Purpose | Dev Setup |
|---------|---------|-----------|
| PostgreSQL 15 | Main database | Docker (port 5433) |
| Keycloak 26.1 | Auth & user management | Docker (port 8180) |
| Superposition | Config & experiments | Docker (port 8080) |
| AWS S3 | File/bundle storage | LocalStack (port 4566) |
| CloudFront | CDN for file delivery | Optional in dev |

### Optional Services (Analytics)

| Service | Purpose |
|---------|---------|
| Apache Kafka | Event streaming |
| ClickHouse | Analytical queries |
| Grafana | Visualization |
| Victoria Metrics | Time-series storage |

### Docker Images (Published to GHCR)

- `ghcr.io/juspay/airborne-server:VERSION`
- `ghcr.io/juspay/airborne-analytics-server:VERSION`
- `ghcr.io/juspay/airborne-dashboard:VERSION`

All images support multi-arch: `linux/amd64` and `linux/arm64`.

### Local Development

```bash
# Using Makefile (recommended)
make setup          # Initialize everything
make db             # Start PostgreSQL
make keycloak       # Start Keycloak
make superposition  # Start Superposition
make localstack     # Start LocalStack (S3 emulation)
make run            # Run the server

# Or using Nix
nix develop         # Enter dev shell with all dependencies
```

### Environment Variables

Key env vars (see `airborne_server/.env.example` for full list):

```bash
# Server
PORT=8081

# Database
DB_HOST=localhost
DB_PORT=5433
DB_NAME=hyperotaserver

# Keycloak
KEYCLOAK_URL=http://localhost:8180
KEYCLOAK_REALM=hyperOTA

# Superposition
SUPERPOSITION_URL=http://localhost:8080

# AWS/S3
AWS_BUCKET=hyper-ota-bucket
AWS_ENDPOINT_URL=http://localhost:4566  # LocalStack

# CloudFront
CLOUDFRONT_DISTRIBUTION_ID=your-dist-id
```

### CI/CD Pipeline

On merge to main:
1. **Tag release**: cocogitto auto-bumps semver based on conventional commits
2. **Build Docker images**: Multi-arch (amd64 + arm64) for server, analytics, dashboard
3. **Publish to Maven Central**: Android SDK
4. **Publish to npm**: RN plugin, CLI tools, server SDK
5. **Create GitHub Release**: Draft with changelog

---

## Quick Reference: File Locations

| What | Where |
|------|-------|
| Server entry point | `airborne_server/src/main.rs` |
| Release serving logic | `airborne_server/src/release.rs` |
| File upload logic | `airborne_server/src/file.rs` |
| Package logic | `airborne_server/src/package.rs` |
| DB migrations | `airborne_server/migrations/` |
| RN plugin JS entry | `airborne-react-native/src/index.tsx` |
| RN Android core | `airborne-react-native/android/.../Airborne.kt` |
| RN Android bridge | `airborne-react-native/android/.../AirborneModuleImpl.kt` |
| RN iOS bridge | `airborne-react-native/ios/AirborneReact.mm` |
| RN iOS core | `airborne-react-native/ios/Airborne.m` |
| DevKit CLI | `airborne_cli/src/index.js` |
| Core CLI | `airborne-core-cli/index.js` |
| Dashboard app | `airborne_dashboard/app/` |
| API definitions | `smithy/models/` |
| Superposition defaults | `airborne_server/superposition-default-configs.json` |
| Docker compose | `airborne_server/docker-compose.yml` |
| CI/CD | `.github/workflows/release.yaml` |
| Version config | `cog.toml` |
