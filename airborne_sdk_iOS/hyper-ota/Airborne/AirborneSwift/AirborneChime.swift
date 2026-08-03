import Foundation
import UIKit

@objc public class AirborneChime: NSObject {

    private static let platform = "ios"

    @objc public static func persistConfig(namespace: String, url: String?, secret: String?, releaseConfigUrl: String?) {
        guard let url = url, !url.isEmpty, let secret = secret, !secret.isEmpty else { return }
        let release = parseReleaseConfigUrl(releaseConfigUrl)
        let defaults = UserDefaults.standard
        defaults.set(url, forKey: key(namespace, "chimeUrl"))
        defaults.set(secret, forKey: key(namespace, "chimeKey"))
        defaults.set(release.org, forKey: key(namespace, "chimeOrg"))
        defaults.set(release.app, forKey: key(namespace, "chimeApp"))
    }

    @objc public static func persistJobId(namespace: String, jobId: String?) {
        guard let jobId = jobId, !jobId.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key(namespace, "chimeJobId"))
            return
        }
        UserDefaults.standard.set(jobId, forKey: key(namespace, "chimeJobId"))
    }

    @objc(persistUserIdForNamespace:userId:)
    public static func persistUserId(namespace: String, userId: String?) {
        guard let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty, !invalidUserIds.contains(userId) else {
            return
        }
        UserDefaults.standard.set(userId, forKey: key(namespace, "chimeUserId"))
    }

    @objc public static func postFunnel(namespace: String,
                                        stage: String,
                                        version: String?,
                                        errorCode: String? = nil,
                                        terminal: Bool = false) {
        let defaults = UserDefaults.standard
        guard let baseUrl = defaults.string(forKey: key(namespace, "chimeUrl")), !baseUrl.isEmpty,
              let secret = defaults.string(forKey: key(namespace, "chimeKey")), !secret.isEmpty,
              let jobId = defaults.string(forKey: key(namespace, "chimeJobId")), !jobId.isEmpty else {
            return
        }

        var body: [String: Any] = [
            "job_id": jobId,
            "stage": stage,
            "package": Bundle.main.bundleIdentifier ?? "",
            "os": platform,
            "airborne_org": defaults.string(forKey: key(namespace, "chimeOrg")) ?? "",
            "airborne_app": defaults.string(forKey: key(namespace, "chimeApp")) ?? ""
        ]
        if let version = version { body["version"] = version }
        if let resolvedUserId = currentUserId(namespace) { body["user_id"] = resolvedUserId }
        if let errorCode = errorCode { body["error_code"] = errorCode }

        let trimmed = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(trimmed)/funnel"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: "X-Event-Key")
        request.httpBody = payload

        if terminal {
            defaults.removeObject(forKey: key(namespace, "chimeJobId"))
        }

        send(request)
    }

    private static func send(_ request: URLRequest) {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var taskId = UIBackgroundTaskIdentifier.invalid
            let endTask = {
                DispatchQueue.main.async {
                    if taskId != .invalid {
                        app.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                }
            }
            taskId = app.beginBackgroundTask(withName: "in.juspay.airborne.chime") {
                endTask()
            }
            URLSession.shared.dataTask(with: request) { _, _, _ in
                endTask()
            }.resume()
        }
    }

    private static let invalidUserIds: Set<String> = ["NO_CUSTOMER_ID", "__failed", "(failed)"]

    private static func currentUserId(_ namespace: String) -> String? {
        let defaults = UserDefaults.standard
        let candidates = [defaults.string(forKey: key(namespace, "chimeUserId")),
                          defaults.string(forKey: "CUSTOMER_ID")]
        for candidate in candidates {
            guard let id = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !invalidUserIds.contains(id) else {
                continue
            }
            return id
        }
        return nil
    }

    private static func parseReleaseConfigUrl(_ releaseConfigUrl: String?) -> (org: String, app: String) {
        guard let raw = releaseConfigUrl, let url = URL(string: raw) else { return ("", "") }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count >= 2 else { return ("", "") }
        return (segments[segments.count - 2], segments[segments.count - 1])
    }

    private static func key(_ namespace: String, _ suffix: String) -> String {
        return "airborne.bg.\(namespace).\(suffix)"
    }
}
