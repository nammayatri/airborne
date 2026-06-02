//
//  AJPRollbackStore.swift
//  Airborne
//
//  Copyright © Juspay Technologies. All rights reserved.
//

import Foundation
#if SWIFT_PACKAGE
import AirborneSwiftCore
import AirborneSwiftModel
import AirborneObjC
#endif

enum AJPBootDecision {
    case normal
    case trial
    case rolledBack
}

final class AJPRollbackStore {

    static let maxTrialBootAttempts = 2
    private static let maxFailedHistory = 20

    private let workspace: String
    private let fileUtil: AJPFileUtil
    private let tracker: AJPApplicationTracker
    private let defaults = UserDefaults.standard

    init(workspace: String, fileUtil: AJPFileUtil, tracker: AJPApplicationTracker) {
        self.workspace = workspace
        self.fileUtil = fileUtil
        self.tracker = tracker
    }

    func trialVersion() -> String { defaults.string(forKey: keyTrialVersion) ?? "" }

    func safeVersion() -> String { defaults.string(forKey: keySafeVersion) ?? "" }

    func failedVersions() -> Set<String> {
        Set((defaults.array(forKey: keyFailed) as? [String]) ?? [])
    }

    func isFailed(_ version: String) -> Bool {
        !version.isEmpty && failedVersions().contains(version)
    }

    func isTrialUnconfirmed(_ loadedVersion: String?) -> Bool {
        let trial = trialVersion()
        return !trial.isEmpty && trial == loadedVersion && trial != safeVersion()
    }

    func snapshotActiveAsPrev() {
        if !trialVersion().isEmpty { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: mainDir), fm.fileExists(atPath: pkgManifestPath) else { return }
        do {
            clearPrev()
            try fm.copyItem(atPath: mainDir, toPath: prevDir)
            for pair in manifestPairs where fm.fileExists(atPath: pair.active) {
                try fm.copyItem(atPath: pair.active, toPath: pair.prev)
            }
            NSLog("[Airborne] Snapshotted current bundle to prev before trial install")
            track(info: "ota_snapshot_saved", [:])
        } catch {
            clearPrev()
            track(error: "ota_snapshot_failed", ["error": error.localizedDescription])
        }
    }

    func beginTrial(_ version: String) {
        defaults.set(version, forKey: keyTrialVersion)
        defaults.set(0, forKey: keyTrialAttempts)
    }

    func evaluateBoot(_ activeVersion: String) -> AJPBootDecision {
        let trial = trialVersion()
        if trial.isEmpty { return .normal }
        if trial != activeVersion || trial == safeVersion() {
            clearTrial()
            return .normal
        }
        let attempts = recordBootAttempt()
        if attempts > AJPRollbackStore.maxTrialBootAttempts {
            let restored = restorePrevToActive()
            if !restored { discardActiveOta() }
            markFailed(trial)
            clearTrial()
            NSLog("[Airborne] Rolling back '\(trial)' after \(attempts) boots (restored_previous=\(restored))")
            track(error: "ota_bundle_rolled_back", [
                "failed_version": trial,
                "attempts": attempts,
                "restored_previous": restored
            ])
            return .rolledBack
        }
        NSLog("[Airborne] Trial boot of '\(trial)' (attempt \(attempts) of \(AJPRollbackStore.maxTrialBootAttempts))")
        track(info: "ota_bundle_trial_boot", ["version": trial, "attempt": attempts])
        return .trial
    }

    func markSafe(_ version: String) {
        if version.isEmpty { return }
        defaults.set(version, forKey: keySafeVersion)
        if trialVersion() == version {
            clearTrial()
            clearPrev()
            NSLog("[Airborne] Marked bundle '\(version)' safe")
            track(info: "ota_bundle_marked_safe", ["version": version])
        }
    }

    func markFailed(_ version: String) {
        if version.isEmpty { return }
        var current = (defaults.array(forKey: keyFailed) as? [String]) ?? []
        if current.contains(version) { return }
        current.append(version)
        if current.count > AJPRollbackStore.maxFailedHistory {
            current = Array(current.suffix(AJPRollbackStore.maxFailedHistory))
        }
        defaults.set(current, forKey: keyFailed)
    }

    private func recordBootAttempt() -> Int {
        let next = defaults.integer(forKey: keyTrialAttempts) + 1
        defaults.set(next, forKey: keyTrialAttempts)
        return next
    }

    private func restorePrevToActive() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prevDir) else { return false }
        do {
            if fm.fileExists(atPath: mainDir) { try fm.removeItem(atPath: mainDir) }
            try fm.moveItem(atPath: prevDir, toPath: mainDir)
            for pair in manifestPairs {
                if fm.fileExists(atPath: pair.active) { try fm.removeItem(atPath: pair.active) }
                if fm.fileExists(atPath: pair.prev) {
                    try fm.moveItem(atPath: pair.prev, toPath: pair.active)
                }
            }
            clearPrev()
            return true
        } catch {
            track(error: "ota_restore_failed", ["error": error.localizedDescription])
            return false
        }
    }

    private func discardActiveOta() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: mainDir)
        for pair in manifestPairs { try? fm.removeItem(atPath: pair.active) }
        clearPrev()
    }

    private func clearPrev() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: prevDir)
        for pair in manifestPairs { try? fm.removeItem(atPath: pair.prev) }
    }

    private func clearTrial() {
        defaults.set("", forKey: keyTrialVersion)
        defaults.set(0, forKey: keyTrialAttempts)
    }

    private var mainDir: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.JUSPAY_MAIN_DIR, inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
    }

    private var prevDir: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.JUSPAY_PREV_DIR, inFolder: AJPApplicationConstants.JUSPAY_PACKAGE_DIR)
    }

    private var pkgManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_PACKAGE_DATA_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var prevManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_PACKAGE_DATA_PREV_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var configManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_CONFIG_DATA_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var prevConfigManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_CONFIG_DATA_PREV_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var resourcesManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_RESOURCES_DATA_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var prevResourcesManifestPath: String {
        fileUtil.fullPathInStorageForFilePath(AJPApplicationConstants.APP_RESOURCES_DATA_PREV_FILE_NAME, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
    }

    private var manifestPairs: [(active: String, prev: String)] {
        [
            (pkgManifestPath, prevManifestPath),
            (configManifestPath, prevConfigManifestPath),
            (resourcesManifestPath, prevResourcesManifestPath)
        ]
    }

    private var keyTrialVersion: String { AJPRollbackStore.keyTrialVersion(workspace) }
    private var keyTrialAttempts: String { AJPRollbackStore.keyTrialAttempts(workspace) }
    private var keySafeVersion: String { AJPRollbackStore.keySafeVersion(workspace) }
    private var keyFailed: String { AJPRollbackStore.keyFailed(workspace) }

    private static func keyTrialVersion(_ ws: String) -> String { "airborne.trial.\(ws).version" }
    private static func keyTrialAttempts(_ ws: String) -> String { "airborne.trial.\(ws).attempts" }
    private static func keySafeVersion(_ ws: String) -> String { "airborne.safe.\(ws).version" }
    private static func keyFailed(_ ws: String) -> String { "airborne.failed.\(ws)" }

    static func clearPersistedState(workspace: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: keyTrialVersion(workspace))
        d.removeObject(forKey: keyTrialAttempts(workspace))
        d.removeObject(forKey: keySafeVersion(workspace))
        d.removeObject(forKey: keyFailed(workspace))
    }

    private func track(info key: String, _ value: [String: Any]) {
        tracker.trackInfo(key, value: NSMutableDictionary(dictionary: value))
    }

    private func track(error key: String, _ value: [String: Any]) {
        tracker.trackError(key, value: NSMutableDictionary(dictionary: value))
    }
}
