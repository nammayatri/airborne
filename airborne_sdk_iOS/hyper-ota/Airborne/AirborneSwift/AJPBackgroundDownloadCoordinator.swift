//
//  AJPBackgroundDownloadCoordinator.swift
//  Airborne
//
//  Copyright © Juspay Technologies. All rights reserved.
//
//  Internal SPI. Consumers should call AirborneServices.startBackgroundDownload(...) instead.
//

import Foundation
import UIKit
import os.log
#if SWIFT_PACKAGE
import AirborneSwiftCore
import AirborneSwiftModel
import AirborneObjC
#endif

// MARK: - Pending-state dictionary keys

private enum BgPendingKey {
    static let sessionIdentifier = "session_identifier"
    static let targetPackageVersion = "target_package_version"
    static let targetConfigVersion = "target_config_version"
    static let expectedTaskDescriptions = "expected_task_descriptions"
    static let completedTaskDescriptions = "completed_task_descriptions"
    static let failedTaskDescriptions = "failed_task_descriptions"
    static let manifestArchive = "manifest_archived_data"
    static let startedAt = "started_at"
}

// MARK: - taskDescription JSON keys

private enum BgTaskKey {
    static let filePath = "filePath"
    static let checksum = "checksum"
    static let kind = "kind"
    static let kindPackage = "package"
    static let kindResource = "resource"
    static let decompress = "decompress"
}

// MARK: - URLSession + timeouts

private let kBgSessionIdentifierPrefix = "in.juspay.airborne.bg."

/// Tight because the silent-push handler must return inside iOS's ~30s budget.
private let kBgRcFetchTimeoutSeconds: TimeInterval = 10.0
private let kBgOnDemandRcFetchTimeoutSeconds: TimeInterval = 60.0
private let kBgForegroundTaskTimeoutSeconds: TimeInterval = 300.0
/// Matches Android's `downloadUpdate(timeoutMs = 600_000L)`.
private let kBgForegroundCycleTimeoutSeconds: TimeInterval = 600.0

// MARK: - os_log

private let bgLog = OSLog(subsystem: "in.juspay.Airborne", category: "BackgroundDownload")

// MARK: -

/// Per-namespace bg downloader. State persists in `app-bg-pending.dat` to survive process death.
@objc(AJPBackgroundDownloadCoordinator)
@objcMembers public final class AJPBackgroundDownloadCoordinator: NSObject {

    // MARK: - Singleton registry

    private static let registryQueue = DispatchQueue(
        label: "in.juspay.Airborne.bgCoordinatorRegistry",
        attributes: .concurrent)
    private static var coordinators: [String: AJPBackgroundDownloadCoordinator] = [:]

    @objc(sharedInstanceForNamespace:)
    public static func sharedInstance(forNamespace aNamespace: String) -> AJPBackgroundDownloadCoordinator? {
        guard !aNamespace.isEmpty else { return nil }

        var existing: AJPBackgroundDownloadCoordinator?
        registryQueue.sync {
            existing = coordinators[aNamespace]
        }
        if let existing = existing { return existing }

        let fresh = AJPBackgroundDownloadCoordinator(namespace: aNamespace)
        var resolved: AJPBackgroundDownloadCoordinator = fresh
        registryQueue.sync(flags: .barrier) {
            if let raced = coordinators[aNamespace] {
                resolved = raced
            } else {
                coordinators[aNamespace] = fresh
                resolved = fresh
            }
        }
        return resolved
    }

    @objc(coordinatorForBackgroundSessionIdentifier:)
    public static func coordinator(forBackgroundSessionIdentifier identifier: String) -> AJPBackgroundDownloadCoordinator? {
        guard identifier.hasPrefix(kBgSessionIdentifierPrefix) else { return nil }
        let ns = String(identifier.dropFirst(kBgSessionIdentifierPrefix.count))
        guard !ns.isEmpty else { return nil }
        guard let coordinator = sharedInstance(forNamespace: ns) else { return nil }
        // Materialize the URLSession so the OS can deliver pending events.
        _ = coordinator.bgSession
        return coordinator
    }

    // MARK: - Instance state

    private let namespace: String
    private let sessionIdentifier: String
    private let fileUtil: AJPFileUtil
    private let stateQueue: DispatchQueue
    private let tracker: AJPApplicationTracker
    private let sessionLock = NSLock()
    private var _bgSession: URLSession?
    private var loggerAttached = false

    /// Invoked after urlSessionDidFinishEvents finalizes installation.
    @objc public var systemCompletionHandler: (() -> Void)?

    private init(namespace: String) {
        self.namespace = namespace
        self.sessionIdentifier = kBgSessionIdentifierPrefix + namespace
        self.fileUtil = AJPFileUtil(workspace: namespace, baseBundle: nil)
        self.stateQueue = DispatchQueue(label: "in.juspay.airborne.bg.\(namespace).state")
        self.tracker = AJPApplicationTracker(managerId: UUID().uuidString.lowercased(), workspace: namespace)
        super.init()
    }

    @objc public var hasInflightDownload: Bool {
        let path = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.APP_BG_PENDING_DATA_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - URLSession (lazy)

    private var bgSession: URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let session = _bgSession {
            return session
        }
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _bgSession = session
        return session
    }

    // MARK: - Tracking

    private func attachLoggerLazily() {
        if loggerAttached { return }
        if let svc = AirborneServices.registeredInstance(forNamespace: namespace) {
            tracker.addLogger(svc as? AJPLoggerDelegate)
            loggerAttached = true
        }
    }

    private func trackInfo(_ key: String, value: [String: Any]) {
        attachLoggerLazily()
        let map = NSMutableDictionary(dictionary: value)
        map["namespace"] = namespace
        tracker.trackInfo(key, value: map)
        os_log("[%{public}@] %{public}@ %{public}@", log: bgLog, type: .info, namespace, key, "\(map)")
    }

    private func trackError(_ key: String, value: [String: Any]) {
        attachLoggerLazily()
        let map = NSMutableDictionary(dictionary: value)
        map["namespace"] = namespace
        tracker.trackError(key, value: map)
        os_log("[%{public}@] %{public}@ %{public}@", log: bgLog, type: .error, namespace, key, "\(map)")
    }

    // MARK: - Persisted state I/O

    private func readPendingState() -> [String: Any]? {
        let path = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.APP_BG_PENDING_DATA_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let allowed: [AnyClass] = [NSDictionary.self, NSString.self, NSNumber.self,
                                   NSDate.self, NSSet.self, NSArray.self, NSData.self]
        guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowed, from: data) as? [String: Any] else {
            return nil
        }
        return decoded
    }

    @discardableResult
    private func writePendingState(_ state: [String: Any]) -> Bool {
        let nsDict = NSDictionary(dictionary: state)
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: nsDict, requiringSecureCoding: false)
            try fileUtil.saveFileWithData(data,
                                          fileName: AJPApplicationConstants.APP_BG_PENDING_DATA_FILE_NAME,
                                          folderName: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
            return true
        } catch {
            trackError("bg_pending_write_failed", value: ["error": error.localizedDescription])
            return false
        }
    }

    private func deletePendingState() {
        try? fileUtil.deleteFile(AJPApplicationConstants.APP_BG_PENDING_DATA_FILE_NAME,
                                  inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    // MARK: - Cancel / reset

    @objc public func cancelAndReset() {
        sessionLock.lock()
        if let session = _bgSession {
            session.invalidateAndCancel()
            _bgSession = nil
        }
        sessionLock.unlock()

        deletePendingState()
        try? fileUtil.deleteFile(AJPApplicationConstants.APP_MANIFEST_DATA_TEMP_FILE_NAME,
                                  inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        clearPackageTempDirectory()
        clearResourceStagingDirectory()
    }

    /// Purges pending state older than 24h that never delivered urlSessionDidFinishEvents.
    @objc public func cleanupStaleStateIfNeeded() {
        guard let state = readPendingState() else { return }
        guard let startedAt = state[BgPendingKey.startedAt] as? Date else {
            cancelAndReset()
            return
        }
        // Clamp against backward wall-clock jumps so a wrong reading doesn't trip the 24h purge.
        let ageSeconds = max(0, -startedAt.timeIntervalSinceNow)
        if ageSeconds > 24 * 60 * 60 {
            trackInfo("stale_bg_pending_cleared", value: ["age_hours": ageSeconds / 3600.0])
            cancelAndReset()
        }
    }

    private func clearPackageTempDirectory() {
        let path = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.JUSPAY_TEMP_DIR,
            inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Safe to call unconditionally — the live bundle reads from JuspayPackages/<ns>/main, never here.
    private func clearResourceStagingDirectory() {
        let path = fileUtil.fullPathInStorageForFilePath("", inFolder: AJPApplicationConstants.JUSPAY_RESOURCE_DIR)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for entry in entries {
                try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(entry))
            }
        }
    }

    // MARK: - Push entry point

    @objc(startDownloadFromPushWithCompletion:)
    public func startDownloadFromPush(completion fetchHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Defer to next cold launch when an unconsumed temp marker is already on disk.
        let pkgTempPath = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.APP_PACKAGE_DATA_TEMP_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        if FileManager.default.fileExists(atPath: pkgTempPath) {
            trackInfo("bg_download_skip_unconsumed_temp", value: [:])
            fetchHandler(.noData)
            return
        }

        let defaults = UserDefaults.standard
        guard let rcUrl = defaults.string(forKey: "airborne.bg.\(namespace).rcUrl"), !rcUrl.isEmpty else {
            trackError("bg_download_failed", value: ["reason": "no_persisted_config"])
            fetchHandler(.failed)
            return
        }
        let dimensions = readPersistedDimensions()
        let fetchUrl = appendStickyTossToURL(rcUrl)

        fetchReleaseConfig(from: fetchUrl, dimensions: dimensions, timeout: kBgRcFetchTimeoutSeconds) { [weak self] manifest, error in
            guard let self = self else { fetchHandler(.failed); return }
            guard let manifest = manifest else {
                self.trackError("bg_download_failed", value: [
                    "reason": "rc_fetch_failed",
                    "error": error?.localizedDescription ?? "unknown"
                ])
                fetchHandler(.failed)
                return
            }
            self.continuePushFlow(with: manifest, fetchHandler: fetchHandler)
        }
    }

    private func continuePushFlow(with newManifest: AJPApplicationManifest, fetchHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let currentPackage = readCurrentPackage()
        let currentResources = readCurrentResources()

        let importants = importantSplitsToDownload(newPackage: newManifest.package, currentPackage: currentPackage)
        let resources = resourcesToDownload(newResources: newManifest.resources, currentResources: currentResources)

        if importants.isEmpty && resources.isEmpty {
            trackInfo("bg_download_no_diff", value: ["target_package_version": newManifest.package.version])
            fetchHandler(.noData)
            return
        }

        if let existing = readPendingState() {
            let existingTarget = (existing[BgPendingKey.targetPackageVersion] as? String) ?? ""
            if existingTarget == newManifest.package.version {
                trackInfo("bg_download_duplicate_push", value: ["target_package_version": existingTarget])
                fetchHandler(.noData)
                return
            }
            trackInfo("bg_download_supersedes_in_flight", value: [
                "existing": existingTarget,
                "new": newManifest.package.version
            ])
            cancelAndReset()
        }

        clearPackageTempDirectory()
        let pkgTempDir = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.JUSPAY_TEMP_DIR,
            inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
        fileUtil.createFolderIfDoesNotExist(pkgTempDir)
        clearResourceStagingDirectory()
        let resourceStagingDir = fileUtil.fullPathInStorageForFilePath("",
            inFolder: AJPApplicationConstants.JUSPAY_RESOURCE_DIR)
        fileUtil.createFolderIfDoesNotExist(resourceStagingDir)

        do {
            try fileUtil.writeInstance(newManifest,
                                       fileName: AJPApplicationConstants.APP_MANIFEST_DATA_TEMP_FILE_NAME,
                                       inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        } catch {
            trackError("bg_download_failed", value: [
                "reason": "manifest_save_failed",
                "error": error.localizedDescription
            ])
            fetchHandler(.failed)
            return
        }

        var expected = Set<String>()
        var tasks: [URLSessionDownloadTask] = []
        let session = bgSession

        for split in importants {
            let shouldDecompress = split.url == newManifest.package.index.url
            if let task = downloadTaskForResource(split, kind: BgTaskKey.kindPackage, decompress: shouldDecompress, session: session) {
                expected.insert(split.filePath)
                tasks.append(task)
            }
        }
        for resource in resources {
            if let task = downloadTaskForResource(resource, kind: BgTaskKey.kindResource, decompress: false, session: session) {
                expected.insert(resource.filePath)
                tasks.append(task)
            }
        }

        if expected.isEmpty {
            trackInfo("bg_download_no_tasks_after_filter", value: [:])
            fetchHandler(.noData)
            return
        }

        // Persist BEFORE resume so an immediate task callback still finds the state on disk.
        let manifestArchive: Data
        do {
            manifestArchive = try NSKeyedArchiver.archivedData(withRootObject: newManifest, requiringSecureCoding: true)
        } catch {
            trackError("bg_download_failed", value: [
                "reason": "manifest_archive_failed",
                "error": error.localizedDescription
            ])
            fetchHandler(.failed)
            return
        }

        let state: [String: Any] = [
            BgPendingKey.sessionIdentifier: sessionIdentifier,
            BgPendingKey.targetPackageVersion: newManifest.package.version,
            BgPendingKey.targetConfigVersion: newManifest.config.version,
            BgPendingKey.expectedTaskDescriptions: NSSet(set: expected),
            BgPendingKey.completedTaskDescriptions: NSSet(),
            BgPendingKey.failedTaskDescriptions: NSSet(),
            BgPendingKey.manifestArchive: manifestArchive,
            BgPendingKey.startedAt: Date()
        ]
        if !writePendingState(state) {
            for task in tasks { task.cancel() }
            fetchHandler(.failed)
            return
        }

        for task in tasks {
            task.resume()
        }

        trackInfo("bg_download_started", value: [
            "target_package_version": newManifest.package.version,
            "task_count": tasks.count
        ])

        fetchHandler(.newData)
    }

    // MARK: - Diff helpers

    private func readCurrentPackage() -> AJPApplicationPackage? {
        return (try? fileUtil.getDecodedInstanceForClass(
            AJPApplicationPackage.self,
            withContentOfFileName: AJPApplicationConstants.APP_PACKAGE_DATA_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)) as? AJPApplicationPackage
    }

    private func readCurrentResources() -> AJPApplicationResources? {
        return (try? fileUtil.getDecodedInstanceForClass(
            AJPApplicationResources.self,
            withContentOfFileName: AJPApplicationConstants.APP_RESOURCES_DATA_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)) as? AJPApplicationResources
    }

    private func importantSplitsToDownload(newPackage: AJPApplicationPackage, currentPackage: AJPApplicationPackage?) -> [AJPResource] {
        var currentByPath: [String: AJPResource] = [:]
        if let current = currentPackage {
            for split in current.allImportantSplits() {
                currentByPath[split.filePath] = split
            }
        }
        var toDownload: [AJPResource] = []
        for split in newPackage.allImportantSplits() {
            let current = currentByPath[split.filePath]
            if Self.shouldDownloadResource(split, existing: current) {
                toDownload.append(split)
            }
        }
        return toDownload
    }

    private func resourcesToDownload(newResources: AJPApplicationResources?, currentResources: AJPApplicationResources?) -> [AJPResource] {
        guard let newResources = newResources else { return [] }
        var toDownload: [AJPResource] = []
        for (key, new) in newResources.resources {
            let current = currentResources?.resources[key]
            if Self.shouldDownloadResource(new, existing: current) {
                toDownload.append(new)
            }
        }
        return toDownload
    }

    /// Mirrors AJPApplicationManagerUtils.shouldDownloadResource (private).
    static func shouldDownloadResource(_ new: AJPResource?, existing: AJPResource?) -> Bool {
        guard let existing = existing else { return true }
        guard let new = new else { return false }
        if new.url.absoluteString != existing.url.absoluteString { return true }
        let newChecksum = new.checksum ?? ""
        let existingChecksum = existing.checksum ?? ""
        if !newChecksum.isEmpty && !existingChecksum.isEmpty {
            return newChecksum != existingChecksum
        }
        return true
    }

    // MARK: - URLSession task setup

    private func downloadTaskForResource(_ resource: AJPResource, kind: String, decompress: Bool, session: URLSession) -> URLSessionDownloadTask? {
        let request = URLRequest(url: resource.url)
        let task = session.downloadTask(with: request)
        let meta: [String: String] = [
            BgTaskKey.filePath: resource.filePath,
            BgTaskKey.checksum: resource.checksum ?? "",
            BgTaskKey.kind: kind,
            BgTaskKey.decompress: decompress ? "true" : "false"
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: meta, options: []) {
            task.taskDescription = String(data: jsonData, encoding: .utf8)
        }
        return task
    }

    // MARK: - State mutation under serial queue

    private func markFilePath(_ filePath: String, asCompleted: Bool) {
        stateQueue.sync {
            guard var state = readPendingState() else { return }
            let key = asCompleted ? BgPendingKey.completedTaskDescriptions : BgPendingKey.failedTaskDescriptions
            let existing = (state[key] as? NSSet) ?? NSSet()
            let updated = NSMutableSet(set: existing)
            updated.add(filePath)
            state[key] = NSSet(set: updated)
            writePendingState(state)
        }
    }

    // MARK: - Finalization

    private func maybeFinalizeInstallation() {
        guard let state = readPendingState() else { return }

        let expected = (state[BgPendingKey.expectedTaskDescriptions] as? NSSet) ?? NSSet()
        let completed = (state[BgPendingKey.completedTaskDescriptions] as? NSSet) ?? NSSet()
        let failed = (state[BgPendingKey.failedTaskDescriptions] as? NSSet) ?? NSSet()

        if completed.count + failed.count < expected.count {
            return
        }

        // Clamp against wall-clock jumps so analytics doesn't see negative/absurd values.
        let startedAt = state[BgPendingKey.startedAt] as? Date
        let timeTakenMs: TimeInterval = startedAt.map {
            max(0, min(-$0.timeIntervalSinceNow * 1000, 24 * 60 * 60 * 1000))
        } ?? 0

        if failed.count > 0 {
            trackError("bg_download_failed", value: [
                "reason": "task_failures",
                "failed_count": failed.count,
                "completed_count": completed.count,
                "time_taken_ms": timeTakenMs
            ])
            cleanupAfterFailure()
            return
        }

        guard let archive = state[BgPendingKey.manifestArchive] as? Data,
              let manifest = try? NSKeyedUnarchiver.unarchivedObject(ofClass: AJPApplicationManifest.self, from: archive) else {
            trackError("bg_download_failed", value: ["reason": "manifest_unarchive_failed"])
            cleanupAfterFailure()
            return
        }

        do {
            try fileUtil.writeInstance(manifest.package,
                                       fileName: AJPApplicationConstants.APP_PACKAGE_DATA_TEMP_FILE_NAME,
                                       inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        } catch {
            trackError("bg_download_failed", value: [
                "reason": "package_temp_write_failed",
                "error": error.localizedDescription
            ])
            cleanupAfterFailure()
            return
        }

        try? fileUtil.writeInstance(manifest.resources,
                                    fileName: AJPApplicationConstants.APP_TEMP_RESOURCES_DATA_FILE_NAME,
                                    inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)

        deletePendingState()
        try? fileUtil.deleteFile(AJPApplicationConstants.APP_MANIFEST_DATA_TEMP_FILE_NAME,
                                  inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)

        trackInfo("bg_download_session_finished", value: [
            "target_package_version": manifest.package.version,
            "completed_count": completed.count,
            "time_taken_ms": timeTakenMs
        ])

        // No exit(0) — App Store §4.5.4 prohibits programmatic termination. Next cold launch promotes.
    }

    private func cleanupAfterFailure() {
        deletePendingState()
        try? fileUtil.deleteFile(AJPApplicationConstants.APP_MANIFEST_DATA_TEMP_FILE_NAME,
                                  inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        clearPackageTempDirectory()
        clearResourceStagingDirectory()
    }

    // MARK: - Inspect-only RC fetch (checkForUpdate)

    /// Resolves on the main queue with JSON of the same shape Android returns:
    ///   `{ available, currentVersion, serverVersion, mandatory, error? }`.
    @objc(inspectForUpdateWithCompletion:)
    public func inspectForUpdate(completion: @escaping (String) -> Void) {
        let baseline = installedVersionOnDisk()

        let defaults = UserDefaults.standard
        guard let rcUrl = defaults.string(forKey: "airborne.bg.\(namespace).rcUrl"), !rcUrl.isEmpty else {
            DispatchQueue.main.async {
                completion(self.updateCheckResult(current: baseline, error: "NO_PERSISTED_CONFIG"))
            }
            return
        }
        let dimensions = readPersistedDimensions()
        let fetchUrl = appendStickyTossToURL(rcUrl)

        fetchReleaseConfig(from: fetchUrl, dimensions: dimensions, timeout: kBgOnDemandRcFetchTimeoutSeconds) { [weak self] manifest, error in
            guard let self = self else { return }
            guard let manifest = manifest else {
                DispatchQueue.main.async {
                    completion(self.updateCheckResult(current: baseline, error: error?.localizedDescription ?? "RC_FETCH_FAILED"))
                }
                return
            }

            let serverVersion = manifest.package.version
            var mandatory = false
            if let value = manifest.config.properties["mandatory"] as? NSNumber {
                mandatory = value.boolValue
            } else if let value = manifest.config.properties["mandatory"] as? Bool {
                mandatory = value
            }
            let available = baseline.isEmpty || baseline != serverVersion

            let result: [String: Any] = [
                "available": available,
                "currentVersion": baseline,
                "serverVersion": serverVersion,
                "mandatory": mandatory
            ]
            DispatchQueue.main.async {
                completion(self.jsonString(from: result))
            }
        }
    }

    private func installedVersionOnDisk() -> String {
        // Pending swap is what the next cold launch will load, so it wins.
        if let tempPkg = (try? fileUtil.getDecodedInstanceForClass(
            AJPApplicationPackage.self,
            withContentOfFileName: AJPApplicationConstants.APP_PACKAGE_DATA_TEMP_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)) as? AJPApplicationPackage,
           !tempPkg.version.isEmpty {
            return tempPkg.version
        }
        if let current = readCurrentPackage(), !current.version.isEmpty {
            return current.version
        }
        // Fresh install fallback to IPA-bundled version so we don't always look out-of-date.
        if let bundledData = try? fileUtil.getFileDataFromBundle("release_config.json"),
           let manifest = try? AJPApplicationManifest(data: bundledData as NSData),
           !manifest.package.version.isEmpty {
            return manifest.package.version
        }
        return ""
    }

    private func updateCheckResult(current: String, error: String) -> String {
        let result: [String: Any] = [
            "available": false,
            "currentVersion": current,
            "serverVersion": "",
            "mandatory": false,
            "error": error
        ]
        return jsonString(from: result)
    }

    private func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - Foreground download cycle (downloadUpdate)

    @objc(startForegroundDownloadWithCompletion:)
    public func startForegroundDownload(completion: @escaping (Bool) -> Void) {
        // Don't race against an in-flight push-driven download or an unconsumed swap.
        if hasInflightDownload {
            trackInfo("foreground_download_skipped", value: ["reason": "bg_in_flight"])
            DispatchQueue.main.async { completion(false) }
            return
        }
        let pkgTempPath = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.APP_PACKAGE_DATA_TEMP_FILE_NAME,
            inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        if FileManager.default.fileExists(atPath: pkgTempPath) {
            trackInfo("foreground_download_skipped", value: ["reason": "pending_swap_present"])
            DispatchQueue.main.async { completion(true) }
            return
        }

        let defaults = UserDefaults.standard
        guard let rcUrl = defaults.string(forKey: "airborne.bg.\(namespace).rcUrl"), !rcUrl.isEmpty else {
            trackError("foreground_download_failed", value: ["reason": "no_persisted_config"])
            DispatchQueue.main.async { completion(false) }
            return
        }
        let dimensions = readPersistedDimensions()
        let fetchUrl = appendStickyTossToURL(rcUrl)

        fetchReleaseConfig(from: fetchUrl, dimensions: dimensions, timeout: kBgOnDemandRcFetchTimeoutSeconds) { [weak self] manifest, error in
            guard let self = self else { return }
            guard let manifest = manifest else {
                self.trackError("foreground_download_failed", value: [
                    "reason": "rc_fetch_failed",
                    "error": error?.localizedDescription ?? "unknown"
                ])
                DispatchQueue.main.async { completion(false) }
                return
            }

            let currentPackage = self.readCurrentPackage()
            let currentResources = self.readCurrentResources()
            let importants = self.importantSplitsToDownload(newPackage: manifest.package, currentPackage: currentPackage)
            let resources = self.resourcesToDownload(newResources: manifest.resources, currentResources: currentResources)
            if importants.isEmpty && resources.isEmpty {
                self.trackInfo("foreground_download_no_diff", value: ["target_package_version": manifest.package.version])
                DispatchQueue.main.async { completion(true) }
                return
            }
            self.runForegroundDownloads(manifest: manifest, importants: importants, resources: resources, completion: completion)
        }
    }

    private func runForegroundDownloads(manifest: AJPApplicationManifest,
                                        importants: [AJPResource],
                                        resources: [AJPResource],
                                        completion: @escaping (Bool) -> Void) {
        clearPackageTempDirectory()
        let pkgTempDir = fileUtil.fullPathInStorageForFilePath(
            AJPApplicationConstants.JUSPAY_TEMP_DIR,
            inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
        fileUtil.createFolderIfDoesNotExist(pkgTempDir)
        clearResourceStagingDirectory()
        let resourceStagingDir = fileUtil.fullPathInStorageForFilePath("",
            inFolder: AJPApplicationConstants.JUSPAY_RESOURCE_DIR)
        fileUtil.createFolderIfDoesNotExist(resourceStagingDir)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = kBgForegroundTaskTimeoutSeconds
        let fgSession = URLSession(configuration: config)

        let group = DispatchGroup()
        let lock = NSLock()
        var anyFailed = false
        var completed = false

        // Mirrors Android `downloadUpdate(timeoutMs = 600_000L)` — caps the full cycle.
        DispatchQueue.global().asyncAfter(deadline: .now() + kBgForegroundCycleTimeoutSeconds) { [weak self] in
            guard let self = self else { return }
            var shouldCancel = false
            lock.lock()
            if !completed {
                shouldCancel = true
                anyFailed = true
            }
            lock.unlock()
            if shouldCancel {
                self.trackError("foreground_download_failed", value: ["reason": "cycle_timeout"])
                fgSession.invalidateAndCancel()
            }
        }

        let downloadOne: (AJPResource, String) -> Void = { resource, kind in
            group.enter()
            let request = URLRequest(url: resource.url)
            let task = fgSession.dataTask(with: request) { data, response, error in
                defer { group.leave() }

                guard error == nil, let data = data else {
                    lock.lock(); anyFailed = true; lock.unlock()
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lock.lock(); anyFailed = true; lock.unlock()
                    return
                }

                if let expected = resource.checksum, !expected.isEmpty {
                    let computed = AJPHelpers.sha256ForData(data)
                    if computed.lowercased() != expected.lowercased() {
                        self.trackError("foreground_download_task_checksum_mismatch", value: [
                            "filePath": resource.filePath,
                            "expected": expected,
                            "got": computed
                        ])
                        lock.lock(); anyFailed = true; lock.unlock()
                        return
                    }
                }

                let payload: Data
                let shouldDecompress = resource.url == manifest.package.index.url
                if shouldDecompress {
                    do {
                        payload = try AJPCompression.maybeDecompressZip(data)
                    } catch {
                        self.trackError("foreground_download_task_decompress_failed", value: [
                            "filePath": resource.filePath,
                            "error": error.localizedDescription
                        ])
                        lock.lock(); anyFailed = true; lock.unlock()
                        return
                    }
                } else {
                    payload = data
                }

                // Resources stage flat; packages stage under temp/ — matches next-boot promotion.
                let destPath = self.stagingPath(for: resource.filePath, kind: kind)
                do {
                    try payload.write(to: URL(fileURLWithPath: destPath), options: .atomic)
                } catch {
                    self.trackError("foreground_download_task_write_failed", value: [
                        "filePath": resource.filePath,
                        "error": error.localizedDescription
                    ])
                    lock.lock(); anyFailed = true; lock.unlock()
                    return
                }
            }
            task.resume()
        }

        for split in importants { downloadOne(split, BgTaskKey.kindPackage) }
        for resource in resources { downloadOne(resource, BgTaskKey.kindResource) }

        group.notify(queue: DispatchQueue.global()) { [weak self] in
            guard let self = self else { return }

            // Set BEFORE invalidate so the cycle-timeout block can't double-fail.
            lock.lock()
            completed = true
            lock.unlock()

            fgSession.finishTasksAndInvalidate()

            if anyFailed {
                self.trackError("foreground_download_failed", value: ["reason": "task_failures"])
                self.clearPackageTempDirectory()
                self.clearResourceStagingDirectory()
                DispatchQueue.main.async { completion(false) }
                return
            }

            do {
                try self.fileUtil.writeInstance(manifest.package,
                                                fileName: AJPApplicationConstants.APP_PACKAGE_DATA_TEMP_FILE_NAME,
                                                inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
            } catch {
                self.trackError("foreground_download_failed", value: [
                    "reason": "package_temp_write_failed",
                    "error": error.localizedDescription
                ])
                self.clearPackageTempDirectory()
                self.clearResourceStagingDirectory()
                DispatchQueue.main.async { completion(false) }
                return
            }
            try? self.fileUtil.writeInstance(manifest.resources,
                                             fileName: AJPApplicationConstants.APP_TEMP_RESOURCES_DATA_FILE_NAME,
                                             inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)

            self.trackInfo("foreground_download_session_finished", value: ["target_package_version": manifest.package.version])
            DispatchQueue.main.async { completion(true) }
        }
    }

    // MARK: - Foreground RC fetch (within push budget)

    private func fetchReleaseConfig(from urlString: String,
                                    dimensions: [String: String],
                                    timeout: TimeInterval,
                                    completion: @escaping (AJPApplicationManifest?, Error?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil, NSError(domain: "in.juspay.Airborne", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "invalid url"]))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        // Bypass CDN/edge caching — we want what the server has *now*.
        request.setValue("no-cache", forHTTPHeaderField: "cache-control")

        let networkType = AJPNetworkTypeDetector.currentNetworkTypeString()
        if !networkType.isEmpty {
            request.setValue(networkType, forHTTPHeaderField: "x-network-type")
        }
        #if os(iOS)
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "x-os-version")
        #endif
        if let currentPackage = readCurrentPackage(), !currentPackage.version.isEmpty {
            request.setValue(currentPackage.version, forHTTPHeaderField: "x-package-version")
        }

        if !dimensions.isEmpty {
            // Sorted so backend cache keys are stable across launches.
            var dimsHeader = ""
            for key in dimensions.keys.sorted() {
                if let value = dimensions[key] {
                    dimsHeader.append("\(key)=\(value);")
                }
            }
            request.setValue(dimsHeader, forHTTPHeaderField: "x-dimension")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let fgSession = URLSession(configuration: config)

        let task = fgSession.dataTask(with: request) { data, _, error in
            fgSession.finishTasksAndInvalidate()
            if let error = error {
                completion(nil, error)
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(nil, NSError(domain: "in.juspay.Airborne", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "empty response"]))
                return
            }
            do {
                let manifest = try AJPApplicationManifest(data: data as NSData)
                completion(manifest, nil)
            } catch {
                completion(nil, error)
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    private func appendStickyTossToURL(_ url: String) -> String {
        return AJPApplicationManager.appendStickyTossToURL(url, workspace: namespace)
    }

    private func stagingPath(for filePath: String, kind: String) -> String {
        if kind == BgTaskKey.kindResource {
            return fileUtil.fullPathInStorageForFilePath(filePath,
                inFolder: AJPApplicationConstants.JUSPAY_RESOURCE_DIR)
        }
        let relativePath = (AJPApplicationConstants.JUSPAY_TEMP_DIR as NSString).appendingPathComponent(filePath)
        return fileUtil.fullPathInStorageForFilePath(relativePath,
            inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
    }

    private func readPersistedDimensions() -> [String: String] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "airborne.bg.\(namespace).dimensions"),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String] else {
            return [:]
        }
        return parsed
    }

    private func decodeTaskDescription(_ taskDescription: String?) -> [String: String] {
        guard let str = taskDescription, !str.isEmpty,
              let data = str.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String] else {
            return [:]
        }
        return parsed
    }
}

// MARK: - URLSession delegate

extension AJPBackgroundDownloadCoordinator: URLSessionDownloadDelegate {

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let meta = decodeTaskDescription(downloadTask.taskDescription)
        let filePath = meta[BgTaskKey.filePath] ?? ""
        let expectedChecksum = meta[BgTaskKey.checksum] ?? ""
        let kind = meta[BgTaskKey.kind] ?? ""

        guard !filePath.isEmpty, !kind.isEmpty else {
            trackError("bg_download_task_metadata_missing", value: [:])
            return
        }

        // Drop callbacks delivered after cancelAndReset — otherwise leak orphan bytes under temp/.
        guard let pendingState = readPendingState(),
              let expected = pendingState[BgPendingKey.expectedTaskDescriptions] as? NSSet,
              expected.contains(filePath) else {
            trackInfo("bg_download_task_dropped_stale", value: [
                "filePath": filePath,
                "kind": kind
            ])
            return
        }

        // Must read synchronously — `location` is gone once this returns.
        guard let fileData = try? Data(contentsOf: location) else {
            markFilePath(filePath, asCompleted: false)
            return
        }

        if !expectedChecksum.isEmpty {
            let computed = AJPHelpers.sha256ForData(fileData)
            if computed.lowercased() != expectedChecksum.lowercased() {
                trackError("bg_download_task_checksum_mismatch", value: [
                    "filePath": filePath,
                    "expected": expectedChecksum,
                    "got": computed
                ])
                markFilePath(filePath, asCompleted: false)
                return
            }
        }

        let payload: Data
        let shouldDecompress = (meta[BgTaskKey.decompress] ?? "false") == "true"
        if shouldDecompress {
            do {
                payload = try AJPCompression.maybeDecompressZip(fileData)
            } catch {
                trackError("bg_download_task_decompress_failed", value: [
                    "filePath": filePath,
                    "error": error.localizedDescription
                ])
                markFilePath(filePath, asCompleted: false)
                return
            }
        } else {
            payload = fileData
        }

        // Resources stage flat; packages stage under temp/ — matches next-boot promotion.
        let destPath = stagingPath(for: filePath, kind: kind)

        do {
            try payload.write(to: URL(fileURLWithPath: destPath), options: .atomic)
        } catch {
            trackError("bg_download_task_write_failed", value: [
                "filePath": filePath,
                "error": error.localizedDescription
            ])
            markFilePath(filePath, asCompleted: false)
            return
        }

        markFilePath(filePath, asCompleted: true)
        trackInfo("bg_download_task_completed", value: [
            "filePath": filePath,
            "size_bytes": payload.count,
            "kind": kind
        ])
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        let meta = decodeTaskDescription(task.taskDescription)
        let filePath = meta[BgTaskKey.filePath] ?? ""

        if let error = error, !filePath.isEmpty {
            let nsError = error as NSError
            // .cancelled comes from cancelAndReset; nothing to record.
            if nsError.code != NSURLErrorCancelled {
                if let pendingState = readPendingState(),
                   let expected = pendingState[BgPendingKey.expectedTaskDescriptions] as? NSSet,
                   expected.contains(filePath) {
                    trackError("bg_download_task_failed", value: [
                        "filePath": filePath,
                        "error": error.localizedDescription
                    ])
                    markFilePath(filePath, asCompleted: false)
                }
            }
        }
        maybeFinalizeInstallation()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        maybeFinalizeInstallation()
        let handler: (() -> Void)?
        sessionLock.lock()
        handler = systemCompletionHandler
        systemCompletionHandler = nil
        sessionLock.unlock()
        if let handler = handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}
