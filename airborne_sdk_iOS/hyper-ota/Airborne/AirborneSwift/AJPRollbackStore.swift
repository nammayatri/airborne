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
    private static let stateFileName = "app-rollback-state.dat"

    private struct RollbackState: Codable {
        var trialVersion: String = ""
        var trialAttempts: Int = 0
        var safeVersion: String = ""
        var failedVersions: [String] = []
    }

    private let workspace: String
    private let fileUtil: AJPFileUtil
    private let tracker: AJPApplicationTracker

    init(workspace: String, fileUtil: AJPFileUtil, tracker: AJPApplicationTracker) {
        self.workspace = workspace
        self.fileUtil = fileUtil
        self.tracker = tracker
        migrateLegacyStateIfNeeded()
    }

    func trialVersion() -> String { loadState().trialVersion }

    func safeVersion() -> String { loadState().safeVersion }

    func failedVersions() -> Set<String> { Set(loadState().failedVersions) }

    func isFailed(_ version: String) -> Bool {
        !version.isEmpty && failedVersions().contains(version)
    }

    func isTrialUnconfirmed(_ loadedVersion: String?) -> Bool {
        let state = loadState()
        return !state.trialVersion.isEmpty && state.trialVersion == loadedVersion && state.trialVersion != state.safeVersion
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
        var state = loadState()
        state.trialVersion = version
        state.trialAttempts = 0
        saveState(state)
    }

    func evaluateBoot(_ activeVersion: String) -> AJPBootDecision {
        var state = loadState()
        let trial = state.trialVersion
        if trial.isEmpty { return .normal }
        if trial != activeVersion || trial == state.safeVersion {
            clearTrial()
            return .normal
        }
        state.trialAttempts += 1
        let attempts = state.trialAttempts
        saveState(state)
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
        var state = loadState()
        state.safeVersion = version
        let wasTrial = state.trialVersion == version
        if wasTrial {
            state.trialVersion = ""
            state.trialAttempts = 0
        }
        saveState(state)
        if wasTrial {
            clearPrev()
            NSLog("[Airborne] Marked bundle '\(version)' safe")
            track(info: "ota_bundle_marked_safe", ["version": version])
        }
    }

    func markFailed(_ version: String) {
        if version.isEmpty { return }
        var state = loadState()
        if state.failedVersions.contains(version) { return }
        state.failedVersions.append(version)
        if state.failedVersions.count > AJPRollbackStore.maxFailedHistory {
            state.failedVersions = Array(state.failedVersions.suffix(AJPRollbackStore.maxFailedHistory))
        }
        saveState(state)
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
        var state = loadState()
        state.trialVersion = ""
        state.trialAttempts = 0
        saveState(state)
    }

    private func loadState() -> RollbackState {
        guard let data = try? fileUtil.getFileDataFromInternalStorage(AJPRollbackStore.stateFileName, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR),
              let decoded = try? JSONDecoder().decode(RollbackState.self, from: data) else {
            return RollbackState()
        }
        return decoded
    }

    private func saveState(_ state: RollbackState) {
        do {
            let data = try JSONEncoder().encode(state)
            try fileUtil.saveFileWithData(data, fileName: AJPRollbackStore.stateFileName, folderName: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        } catch {
            track(error: "ota_rollback_state_write_failed", ["error": error.localizedDescription])
        }
    }

    private func migrateLegacyStateIfNeeded() {
        let statePath = fileUtil.fullPathInStorageForFilePath(AJPRollbackStore.stateFileName, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        if FileManager.default.fileExists(atPath: statePath) { return }
        let defaults = UserDefaults.standard
        let trial = defaults.string(forKey: AJPRollbackStore.keyTrialVersion(workspace)) ?? ""
        let safe = defaults.string(forKey: AJPRollbackStore.keySafeVersion(workspace)) ?? ""
        let attempts = defaults.integer(forKey: AJPRollbackStore.keyTrialAttempts(workspace))
        let failed = (defaults.array(forKey: AJPRollbackStore.keyFailed(workspace)) as? [String]) ?? []
        if trial.isEmpty && safe.isEmpty && attempts == 0 && failed.isEmpty { return }
        var state = RollbackState()
        state.trialVersion = trial
        state.trialAttempts = attempts
        state.safeVersion = safe
        state.failedVersions = failed
        saveState(state)
        AJPRollbackStore.removeLegacyDefaults(workspace)
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

    private static func keyTrialVersion(_ ws: String) -> String { "airborne.trial.\(ws).version" }
    private static func keyTrialAttempts(_ ws: String) -> String { "airborne.trial.\(ws).attempts" }
    private static func keySafeVersion(_ ws: String) -> String { "airborne.safe.\(ws).version" }
    private static func keyFailed(_ ws: String) -> String { "airborne.failed.\(ws)" }

    private static func removeLegacyDefaults(_ ws: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: keyTrialVersion(ws))
        d.removeObject(forKey: keyTrialAttempts(ws))
        d.removeObject(forKey: keySafeVersion(ws))
        d.removeObject(forKey: keyFailed(ws))
    }

    static func clearPersistedState(workspace: String) {
        let fileUtil = AJPFileUtil(workspace: workspace, baseBundle: nil)
        try? fileUtil.deleteFile(stateFileName, inFolder: AJPApplicationConstants.JUSPAY_MANIFEST_DIR)
        removeLegacyDefaults(workspace)
    }

    private func track(info key: String, _ value: [String: Any]) {
        tracker.trackInfo(key, value: NSMutableDictionary(dictionary: value))
    }

    private func track(error key: String, _ value: [String: Any]) {
        tracker.trackError(key, value: NSMutableDictionary(dictionary: value))
    }
}
