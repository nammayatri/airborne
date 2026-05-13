//
//  AJPBackgroundDownloadCoordinator.h
//  Airborne
//
//  Copyright © Juspay Technologies. All rights reserved.
//
//  Internal SPI: do not call directly from consumer apps. Use the static facade
//  on AirborneServices (handleSilentPush:fetchCompletionHandler: and
//  handleBackgroundURLSession:identifier:completionHandler:) from the AppDelegate.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if SWIFT_PACKAGE
#import "AJPApplicationManifest.h"
#else
#import <Airborne/AJPApplicationManifest.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Per-namespace coordinator that runs the silent-push-triggered background bundle
/// download. One coordinator per namespace; lazily created. Owns a URLSession with
/// `URLSessionConfiguration.background(withIdentifier:)` and its delegate methods.
///
/// Persisted state (`app-bg-pending.dat`) lives in `~/Library/JuspayManifests/<ns>/`
/// so the flow survives process death between OS-managed task completions.
@interface AJPBackgroundDownloadCoordinator : NSObject <NSURLSessionDownloadDelegate>

/// Returns the singleton coordinator for the given namespace. Returns nil only if
/// the namespace is empty.
+ (nullable instancetype)sharedInstanceForNamespace:(NSString *)aNamespace
    NS_SWIFT_NAME(sharedInstance(forNamespace:));

/// Returns the coordinator owning the given URLSession identifier, or nil if the
/// identifier doesn't match the `in.juspay.airborne.bg.<ns>` prefix.
/// Used by the AppDelegate forwarder to reattach a session on relaunch.
+ (nullable instancetype)coordinatorForBackgroundSessionIdentifier:(NSString *)identifier
    NS_SWIFT_NAME(coordinator(forBackgroundSessionIdentifier:));

/// Stored when AppDelegate.handleEventsForBackgroundURLSession fires; invoked once
/// urlSessionDidFinishEvents has finalized installation.
@property (nonatomic, copy, nullable) void (^systemCompletionHandler)(void);

/// Returns YES if `app-bg-pending.dat` exists for this namespace.
@property (readonly) BOOL hasInflightDownload;

/// Entry point from the static silent-push facade. Performs the full push flow
/// (RC fetch → diff → start URLSession.background tasks → persist pending state)
/// within the OS-imposed ~30s window, then invokes `fetchHandler` with the
/// appropriate UIBackgroundFetchResult.
- (void)startDownloadFromPushWithCompletion:(void (^)(UIBackgroundFetchResult))fetchHandler;

/// Cancels in-flight tasks and clears all transient state for this namespace.
/// Used when a newer push targets a different version, forcing a clean restart.
- (void)cancelAndReset;

/// Read-only check: fetches the release config and reports whether a newer bundle
/// is available, without downloading anything. iOS counterpart of Android's
/// `Airborne.checkForUpdate()`. Calls `completion` on the main queue with a JSON
/// string of the same shape Android returns:
///   { "available": Bool,
///     "currentVersion": String,
///     "serverVersion": String,
///     "mandatory": Bool,
///     "error"?: String }
- (void)inspectForUpdateWithCompletion:(void (^)(NSString *jsonResult))completion
    NS_SWIFT_NAME(inspectForUpdate(completion:));

/// Foreground (non-background-URLSession) download cycle: fetches RC, diffs, downloads
/// missing splits via `URLSessionConfiguration.default`, writes the temp markers, and
/// fires `completion` with `success` only after every task has finished. Intended as
/// the iOS counterpart of Android's `Airborne.downloadUpdate(onComplete:)`.
- (void)startForegroundDownloadWithCompletion:(void (^)(BOOL success))completion
    NS_SWIFT_NAME(startForegroundDownload(completion:));

@end

NS_ASSUME_NONNULL_END
