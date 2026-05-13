//
//  AJPBackgroundDownloadCoordinator.m
//  Airborne
//
//  Copyright © Juspay Technologies. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#import "AJPBackgroundDownloadCoordinator.h"
#import "AJPApplicationManager.h"
#import "AJPApplicationManager+Internal.h"
#import "AJPApplicationConstants.h"
#import "AJPApplicationManifest.h"
#import "AJPApplicationPackage.h"
#import "AJPApplicationResources.h"
#import "AJPResource.h"
#import "AJPApplicationTracker.h"

#if SWIFT_PACKAGE
@import AirborneSwiftCore;
#else
#import <Airborne/Airborne-Swift.h>
#endif

#pragma mark - Pending-state dictionary keys

static NSString *const kBgPendingSessionIdentifier         = @"session_identifier";
static NSString *const kBgPendingTargetPackageVersion      = @"target_package_version";
static NSString *const kBgPendingTargetConfigVersion       = @"target_config_version";
static NSString *const kBgPendingExpectedTaskDescriptions  = @"expected_task_descriptions";
static NSString *const kBgPendingCompletedTaskDescriptions = @"completed_task_descriptions";
static NSString *const kBgPendingFailedTaskDescriptions    = @"failed_task_descriptions";
static NSString *const kBgPendingManifestArchive           = @"manifest_archived_data";
static NSString *const kBgPendingStartedAt                 = @"started_at";

#pragma mark - taskDescription JSON keys

static NSString *const kBgTaskFilePath = @"filePath";
static NSString *const kBgTaskChecksum = @"checksum";
static NSString *const kBgTaskKind     = @"kind";
static NSString *const kBgTaskKindPackage  = @"package";
static NSString *const kBgTaskKindResource = @"resource";

#pragma mark - URLSession identifier

static NSString *const kBgSessionIdentifierPrefix = @"in.juspay.airborne.bg.";

#pragma mark - Network timeouts

// Silent-push handler must return inside iOS's ~30s push budget — leave room for
// diff + URLSession.background scheduling, so RC fetch is intentionally tight.
static const NSTimeInterval kBgRcFetchTimeoutSeconds = 10.0;

// On-demand `checkForUpdate` / `downloadUpdate` aren't budget-bound. Mirrors what
// Android's OTANetUtils gives those calls (a default that comfortably fits a small
// release-config response on slow networks).
static const NSTimeInterval kBgOnDemandRcFetchTimeoutSeconds = 60.0;

// Per-split download cap for the foreground `downloadUpdate` cycle.
static const NSTimeInterval kBgForegroundTaskTimeoutSeconds = 300.0;

// Overall cycle cap for `downloadUpdate`. Matches Android's `downloadUpdate(timeoutMs = 600_000L)`.
static const NSTimeInterval kBgForegroundCycleTimeoutSeconds = 600.0;

#pragma mark - os_log

static os_log_t airborne_bg_log(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("in.juspay.Airborne", "BackgroundDownload");
    });
    return logger;
}

#pragma mark -

@interface AJPBackgroundDownloadCoordinator () {
    BOOL _loggerAttached;
}

@property (nonatomic, strong, readonly) NSString *namespace;
@property (nonatomic, strong, readonly) NSString *sessionIdentifier;
@property (nonatomic, strong, readonly) AJPFileUtil *fileUtil;
@property (nonatomic, strong, readonly) dispatch_queue_t stateQueue;
@property (nonatomic, strong, readonly) AJPApplicationTracker *tracker;
@property (nonatomic, strong, nullable) NSURLSession *bgSession;

@end

@implementation AJPBackgroundDownloadCoordinator

#pragma mark - Singleton registry

+ (NSMutableDictionary<NSString *, AJPBackgroundDownloadCoordinator *> *)coordinatorRegistry {
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        registry = [NSMutableDictionary dictionary];
    });
    return registry;
}

+ (dispatch_queue_t)coordinatorRegistryQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("in.juspay.Airborne.bgCoordinatorRegistry", DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

+ (instancetype)sharedInstanceForNamespace:(NSString *)aNamespace {
    if (aNamespace.length == 0) {
        return nil;
    }
    __block AJPBackgroundDownloadCoordinator *coordinator = nil;
    dispatch_sync([self coordinatorRegistryQueue], ^{
        coordinator = [self coordinatorRegistry][aNamespace];
    });
    if (coordinator != nil) {
        return coordinator;
    }
    AJPBackgroundDownloadCoordinator *fresh = [[self alloc] initWithNamespace:aNamespace];
    dispatch_barrier_sync([self coordinatorRegistryQueue], ^{
        AJPBackgroundDownloadCoordinator *raced = [self coordinatorRegistry][aNamespace];
        if (raced != nil) {
            coordinator = raced;
        } else {
            [self coordinatorRegistry][aNamespace] = fresh;
            coordinator = fresh;
        }
    });
    return coordinator;
}

+ (nullable instancetype)coordinatorForBackgroundSessionIdentifier:(NSString *)identifier {
    if (![identifier hasPrefix:kBgSessionIdentifierPrefix]) {
        return nil;
    }
    NSString *ns = [identifier substringFromIndex:kBgSessionIdentifierPrefix.length];
    if (ns.length == 0) {
        return nil;
    }
    AJPBackgroundDownloadCoordinator *coordinator = [self sharedInstanceForNamespace:ns];
    // Eagerly materialize the URLSession so the OS can deliver pending events.
    (void)coordinator.bgSession;
    return coordinator;
}

#pragma mark - Init

- (instancetype)initWithNamespace:(NSString *)aNamespace {
    self = [super init];
    if (self) {
        _namespace = [aNamespace copy];
        _sessionIdentifier = [kBgSessionIdentifierPrefix stringByAppendingString:aNamespace];
        _fileUtil = [[AJPFileUtil alloc] initWithWorkspace:aNamespace baseBundle:nil];
        _stateQueue = dispatch_queue_create([[NSString stringWithFormat:@"in.juspay.airborne.bg.%@.state", aNamespace] UTF8String],
                                            DISPATCH_QUEUE_SERIAL);
        _tracker = [[AJPApplicationTracker alloc] initWithManagerId:[[NSUUID UUID] UUIDString].lowercaseString
                                                          workspace:aNamespace];
        _loggerAttached = NO;
    }
    return self;
}

#pragma mark - URLSession (lazy)

- (NSURLSession *)bgSession {
    @synchronized(self) {
        if (_bgSession != nil) {
            return _bgSession;
        }
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:self.sessionIdentifier];
        config.sessionSendsLaunchEvents = YES;
        config.discretionary = NO;
        config.allowsCellularAccess = YES;
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60;
        _bgSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        return _bgSession;
    }
}

#pragma mark - Public properties

- (BOOL)hasInflightDownload {
    NSString *path = [self.fileUtil fullPathInStorageForFilePath:APP_BG_PENDING_DATA_FILE_NAME
                                                        inFolder:JUSPAY_MANIFEST_DIR];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

#pragma mark - Tracking

- (void)attachLoggerLazily {
    if (_loggerAttached) return;
    AirborneServices *svc = [AirborneServices registeredInstanceForNamespace:self.namespace];
    if (svc != nil) {
        [self.tracker addLogger:(id<AJPLoggerDelegate>)svc];
        _loggerAttached = YES;
    }
}

- (void)trackInfo:(NSString *)key value:(NSDictionary *)value {
    [self attachLoggerLazily];
    NSMutableDictionary *mvalue = [NSMutableDictionary dictionaryWithDictionary:value ?: @{}];
    mvalue[@"namespace"] = self.namespace;
    [self.tracker trackInfo:key value:mvalue];
    os_log_with_type(airborne_bg_log(), OS_LOG_TYPE_INFO, "[%{public}@] %{public}@ %{public}@",
                     self.namespace, key, mvalue);
}

- (void)trackError:(NSString *)key value:(NSDictionary *)value {
    [self attachLoggerLazily];
    NSMutableDictionary *mvalue = [NSMutableDictionary dictionaryWithDictionary:value ?: @{}];
    mvalue[@"namespace"] = self.namespace;
    [self.tracker trackError:key value:mvalue];
    os_log_with_type(airborne_bg_log(), OS_LOG_TYPE_ERROR, "[%{public}@] %{public}@ %{public}@",
                     self.namespace, key, mvalue);
}

#pragma mark - Persisted state I/O

- (NSDictionary * _Nullable)readPendingState {
    NSString *path = [self.fileUtil fullPathInStorageForFilePath:APP_BG_PENDING_DATA_FILE_NAME
                                                        inFolder:JUSPAY_MANIFEST_DIR];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        return nil;
    }
    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readErr];
    if (data == nil) {
        return nil;
    }
    NSSet *allowed = [NSSet setWithObjects:[NSDictionary class], [NSString class],
                      [NSNumber class], [NSDate class], [NSSet class], [NSArray class],
                      [NSData class], nil];
    NSError *decodeErr = nil;
    id decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed fromData:data error:&decodeErr];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)decoded;
}

- (BOOL)writePendingState:(NSDictionary *)state {
    NSError *encodeErr = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:state
                                         requiringSecureCoding:NO
                                                         error:&encodeErr];
    if (data == nil) {
        [self trackError:@"bg_pending_encode_failed"
                   value:@{@"error": encodeErr.localizedDescription ?: @"unknown"}];
        return NO;
    }
    NSError *writeErr = nil;
    BOOL didSave = [self.fileUtil saveFileWithData:data
                                          fileName:APP_BG_PENDING_DATA_FILE_NAME
                                        folderName:JUSPAY_MANIFEST_DIR
                                             error:&writeErr];
    if (!didSave) {
        [self trackError:@"bg_pending_write_failed"
                   value:@{@"error": writeErr.localizedDescription ?: @"unknown"}];
    }
    return didSave;
}

- (void)deletePendingState {
    [self.fileUtil deleteFile:APP_BG_PENDING_DATA_FILE_NAME inFolder:JUSPAY_MANIFEST_DIR error:nil];
}

#pragma mark - Cancel / reset

- (void)cancelAndReset {
    @synchronized(self) {
        if (_bgSession != nil) {
            [_bgSession invalidateAndCancel];
            _bgSession = nil;
        }
    }
    [self deletePendingState];
    [self.fileUtil deleteFile:APP_MANIFEST_DATA_TEMP_FILE_NAME inFolder:JUSPAY_MANIFEST_DIR error:nil];
    [self clearPackageTempDirectory];
    [self clearResourcesTempDirectory];
}

- (void)clearPackageTempDirectory {
    NSString *tempDirPath = [self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                               inFolder:JUSPAY_PACKAGE_DIR];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:tempDirPath]) {
        [fm removeItemAtPath:tempDirPath error:nil];
    }
}

- (void)clearResourcesTempDirectory {
    NSString *tempDirPath = [self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                               inFolder:JUSPAY_RESOURCE_DIR];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:tempDirPath]) {
        [fm removeItemAtPath:tempDirPath error:nil];
    }
}

#pragma mark - Push entry point

- (void)startDownloadFromPushWithCompletion:(void (^)(UIBackgroundFetchResult))fetchHandler {
    // Edge: a previous download has already produced an unconsumed temp marker.
    // Let the next cold launch swap it in before starting another download.
    NSString *pkgTempPath = [self.fileUtil fullPathInStorageForFilePath:APP_PACKAGE_DATA_TEMP_FILE_NAME
                                                               inFolder:JUSPAY_MANIFEST_DIR];
    if ([[NSFileManager defaultManager] fileExistsAtPath:pkgTempPath]) {
        [self trackInfo:@"bg_download_skip_unconsumed_temp" value:@{}];
        fetchHandler(UIBackgroundFetchResultNoData);
        return;
    }

    // Read persisted SDK config (written by AirborneServices.init).
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *rcUrlKey = [NSString stringWithFormat:@"airborne.bg.%@.rcUrl", self.namespace];
    NSString *rcUrl = [defaults stringForKey:rcUrlKey];
    if (rcUrl.length == 0) {
        [self trackError:@"bg_download_failed" value:@{@"reason": @"no_persisted_config"}];
        fetchHandler(UIBackgroundFetchResultFailed);
        return;
    }

    NSString *dimsKey = [NSString stringWithFormat:@"airborne.bg.%@.dimensions", self.namespace];
    NSDictionary<NSString *, NSString *> *dimensions = @{};
    NSData *dimsData = [defaults dataForKey:dimsKey];
    if (dimsData != nil) {
        id parsed = [NSJSONSerialization JSONObjectWithData:dimsData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            dimensions = (NSDictionary *)parsed;
        }
    }

    // RC fetch happens within the OS push budget (~30s). Hard 10s timeout leaves
    // room for diff + saveManifestToTemp + scheduling URLSession.background tasks.
    NSString *fetchUrl = [self appendStickyTossToURL:rcUrl];
    [self fetchReleaseConfigFrom:fetchUrl
                      dimensions:dimensions
                         timeout:kBgRcFetchTimeoutSeconds
                      completion:^(AJPApplicationManifest * _Nullable manifest, NSError * _Nullable error) {
        if (manifest == nil) {
            [self trackError:@"bg_download_failed"
                       value:@{@"reason": @"rc_fetch_failed",
                               @"error": error.localizedDescription ?: @"unknown"}];
            fetchHandler(UIBackgroundFetchResultFailed);
            return;
        }
        [self continuePushFlowWithManifest:manifest fetchHandler:fetchHandler];
    }];
}

- (void)continuePushFlowWithManifest:(AJPApplicationManifest *)newManifest
                        fetchHandler:(void (^)(UIBackgroundFetchResult))fetchHandler {
    // Read currently-installed package + resources for diff.
    AJPApplicationPackage *currentPackage = [self readCurrentPackage];
    AJPApplicationResources *currentResources = [self readCurrentResources];

    // Compute splits to download. Importants only (mirrors Android `downloadUpdate`).
    NSArray<AJPResource *> *importantsToDownload = [self importantSplitsToDownloadFromNewPackage:newManifest.package
                                                                                 currentPackage:currentPackage];
    NSArray<AJPResource *> *resourcesToDownload = [self resourcesToDownloadFromNewResources:newManifest.resources
                                                                          currentResources:currentResources];

    if (importantsToDownload.count == 0 && resourcesToDownload.count == 0) {
        [self trackInfo:@"bg_download_no_diff"
                  value:@{@"target_package_version": newManifest.package.version ?: @""}];
        fetchHandler(UIBackgroundFetchResultNoData);
        return;
    }

    // Duplicate-push and conflict handling.
    NSDictionary *existingPending = [self readPendingState];
    if (existingPending != nil) {
        NSString *existingTarget = existingPending[kBgPendingTargetPackageVersion];
        if ([existingTarget isEqualToString:newManifest.package.version]) {
            [self trackInfo:@"bg_download_duplicate_push"
                      value:@{@"target_package_version": existingTarget ?: @""}];
            fetchHandler(UIBackgroundFetchResultNoData);
            return;
        }
        [self trackInfo:@"bg_download_supersedes_in_flight"
                  value:@{@"existing": existingTarget ?: @"",
                          @"new": newManifest.package.version ?: @""}];
        [self cancelAndReset];
    }

    // Stage temp directory + persist tentative manifest snapshot (consumed only by
    // foreground init's readTempManifest fallback path; the canonical commit happens
    // in finalize via app-pkg-temp.dat).
    [self clearPackageTempDirectory];
    [self.fileUtil createFolderIfDoesNotExist:[self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                                                 inFolder:JUSPAY_PACKAGE_DIR]];
    [self clearResourcesTempDirectory];
    [self.fileUtil createFolderIfDoesNotExist:[self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                                                 inFolder:JUSPAY_RESOURCE_DIR]];

    NSError *manifestSaveErr = nil;
    [self.fileUtil writeInstance:newManifest
                        fileName:APP_MANIFEST_DATA_TEMP_FILE_NAME
                        inFolder:JUSPAY_MANIFEST_DIR
                           error:&manifestSaveErr];
    if (manifestSaveErr != nil) {
        [self trackError:@"bg_download_failed"
                   value:@{@"reason": @"manifest_save_failed",
                           @"error": manifestSaveErr.localizedDescription ?: @"unknown"}];
        fetchHandler(UIBackgroundFetchResultFailed);
        return;
    }

    // Build the expected-task-description set and schedule URLSession.background tasks.
    NSMutableSet<NSString *> *expected = [NSMutableSet set];
    NSMutableArray<NSURLSessionDownloadTask *> *tasks = [NSMutableArray array];

    NSURLSession *session = self.bgSession;
    for (AJPResource *split in importantsToDownload) {
        NSURLSessionDownloadTask *task = [self downloadTaskForResource:split kind:kBgTaskKindPackage session:session];
        if (task != nil) {
            [expected addObject:split.filePath];
            [tasks addObject:task];
        }
    }
    for (AJPResource *resource in resourcesToDownload) {
        NSURLSessionDownloadTask *task = [self downloadTaskForResource:resource kind:kBgTaskKindResource session:session];
        if (task != nil) {
            [expected addObject:resource.filePath];
            [tasks addObject:task];
        }
    }

    if (expected.count == 0) {
        [self trackInfo:@"bg_download_no_tasks_after_filter" value:@{}];
        fetchHandler(UIBackgroundFetchResultNoData);
        return;
    }

    // Persist pending state BEFORE resuming so that any task that fires near-instantly
    // (cached responses, local proxies) finds the state file already on disk.
    NSError *manifestArchiveErr = nil;
    NSData *manifestArchive = [NSKeyedArchiver archivedDataWithRootObject:newManifest
                                                    requiringSecureCoding:YES
                                                                    error:&manifestArchiveErr];
    if (manifestArchive == nil) {
        [self trackError:@"bg_download_failed"
                   value:@{@"reason": @"manifest_archive_failed",
                           @"error": manifestArchiveErr.localizedDescription ?: @"unknown"}];
        fetchHandler(UIBackgroundFetchResultFailed);
        return;
    }

    NSDictionary *state = @{
        kBgPendingSessionIdentifier:         self.sessionIdentifier,
        kBgPendingTargetPackageVersion:      newManifest.package.version ?: @"",
        kBgPendingTargetConfigVersion:       newManifest.config.version ?: @"",
        kBgPendingExpectedTaskDescriptions:  expected,
        kBgPendingCompletedTaskDescriptions: [NSSet set],
        kBgPendingFailedTaskDescriptions:    [NSSet set],
        kBgPendingManifestArchive:           manifestArchive,
        kBgPendingStartedAt:                 [NSDate date]
    };
    if (![self writePendingState:state]) {
        // Cancel scheduled tasks; we can't track them without the state file.
        for (NSURLSessionDownloadTask *task in tasks) {
            [task cancel];
        }
        fetchHandler(UIBackgroundFetchResultFailed);
        return;
    }

    for (NSURLSessionDownloadTask *task in tasks) {
        [task resume];
    }

    [self trackInfo:@"bg_download_started"
              value:@{@"target_package_version": newManifest.package.version ?: @"",
                      @"task_count": @(tasks.count)}];

    fetchHandler(UIBackgroundFetchResultNewData);
}

#pragma mark - Diff helpers

- (AJPApplicationPackage * _Nullable)readCurrentPackage {
    NSError *err = nil;
    id decoded = [self.fileUtil getDecodedInstanceForClass:[AJPApplicationPackage class]
                                     withContentOfFileName:APP_PACKAGE_DATA_FILE_NAME
                                                  inFolder:JUSPAY_MANIFEST_DIR
                                                     error:&err];
    return [decoded isKindOfClass:[AJPApplicationPackage class]] ? decoded : nil;
}

- (AJPApplicationResources * _Nullable)readCurrentResources {
    NSError *err = nil;
    id decoded = [self.fileUtil getDecodedInstanceForClass:[AJPApplicationResources class]
                                     withContentOfFileName:APP_RESOURCES_DATA_FILE_NAME
                                                  inFolder:JUSPAY_MANIFEST_DIR
                                                     error:&err];
    return [decoded isKindOfClass:[AJPApplicationResources class]] ? decoded : nil;
}

- (NSArray<AJPResource *> *)importantSplitsToDownloadFromNewPackage:(AJPApplicationPackage *)newPackage
                                                     currentPackage:(AJPApplicationPackage * _Nullable)currentPackage {
    if (newPackage == nil) {
        return @[];
    }
    NSMutableDictionary<NSString *, AJPResource *> *currentByPath = [NSMutableDictionary dictionary];
    for (AJPResource *split in [currentPackage allImportantSplits]) {
        currentByPath[split.filePath] = split;
    }
    NSMutableArray<AJPResource *> *toDownload = [NSMutableArray array];
    for (AJPResource *split in [newPackage allImportantSplits]) {
        AJPResource *current = currentByPath[split.filePath];
        if ([AJPApplicationManager shouldDownloadResource:split existingResource:current]) {
            [toDownload addObject:split];
        }
    }
    return toDownload;
}

- (NSArray<AJPResource *> *)resourcesToDownloadFromNewResources:(AJPApplicationResources * _Nullable)newResources
                                              currentResources:(AJPApplicationResources * _Nullable)currentResources {
    if (newResources == nil) {
        return @[];
    }
    NSMutableArray<AJPResource *> *toDownload = [NSMutableArray array];
    for (NSString *key in newResources.resources) {
        AJPResource *new = newResources.resources[key];
        AJPResource *current = currentResources.resources[key];
        if ([AJPApplicationManager shouldDownloadResource:new existingResource:current]) {
            [toDownload addObject:new];
        }
    }
    return toDownload;
}

#pragma mark - URLSession task setup

- (NSURLSessionDownloadTask * _Nullable)downloadTaskForResource:(AJPResource *)resource
                                                            kind:(NSString *)kind
                                                         session:(NSURLSession *)session {
    if (resource.url == nil) {
        return nil;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:resource.url];
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request];

    NSDictionary *meta = @{
        kBgTaskFilePath: resource.filePath ?: @"",
        kBgTaskChecksum: resource.checksum ?: @"",
        kBgTaskKind:     kind
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    task.taskDescription = jsonStr;
    return task;
}

#pragma mark - URLSession delegate: per-task completion

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSDictionary *meta = [self decodeTaskDescription:downloadTask.taskDescription];
    NSString *filePath = meta[kBgTaskFilePath];
    NSString *expectedChecksum = meta[kBgTaskChecksum];
    NSString *kind = meta[kBgTaskKind];

    if (filePath.length == 0 || kind.length == 0) {
        [self trackError:@"bg_download_task_metadata_missing" value:@{}];
        return;
    }

    // Read the OS temp file synchronously (must finish before this method returns).
    NSError *readErr = nil;
    NSData *fileData = [NSData dataWithContentsOfURL:location options:0 error:&readErr];
    if (fileData == nil) {
        [self markFilePath:filePath asFailedWithReason:@"read_failed"];
        return;
    }

    // Checksum verification when expected.
    if (expectedChecksum.length > 0) {
        NSString *computed = [AJPHelpers sha256ForData:fileData];
        if (![computed.lowercaseString isEqualToString:expectedChecksum.lowercaseString]) {
            [self trackError:@"bg_download_task_checksum_mismatch"
                       value:@{@"filePath": filePath,
                               @"expected": expectedChecksum,
                               @"got": computed ?: @""}];
            [self markFilePath:filePath asFailedWithReason:@"checksum_mismatch"];
            return;
        }
    }

    // The catalyst-ota uploader may ship the bundle wrapped in a single-entry ZIP
    // regardless of the URL extension — `maybeDecompressZip` sniffs PK\x03\x04 magic
    // bytes and is a no-op for already-raw payloads. Matches AJPRemoteFileUtil's
    // foreground download contract.
    NSError *decompErr = nil;
    NSData *payload = [AJPHelpers maybeDecompressZip:fileData error:&decompErr];
    if (payload == nil) {
        [self trackError:@"bg_download_task_decompress_failed"
                   value:@{@"filePath": filePath,
                           @"error": decompErr.localizedDescription ?: @"unknown"}];
        [self markFilePath:filePath asFailedWithReason:@"decompress_failed"];
        return;
    }

    // Resolve destination under <packagesOrResources>/<ns>/temp/<filePath> and write atomically.
    NSString *folderName = [kind isEqualToString:kBgTaskKindResource] ? JUSPAY_RESOURCE_DIR : JUSPAY_PACKAGE_DIR;
    NSString *relativePath = [JUSPAY_TEMP_DIR stringByAppendingPathComponent:filePath];
    NSString *destPath = [self.fileUtil fullPathInStorageForFilePath:relativePath inFolder:folderName];

    NSError *writeErr = nil;
    BOOL didWrite = [payload writeToFile:destPath options:NSDataWritingAtomic error:&writeErr];
    if (!didWrite) {
        [self trackError:@"bg_download_task_write_failed"
                   value:@{@"filePath": filePath,
                           @"error": writeErr.localizedDescription ?: @"unknown"}];
        [self markFilePath:filePath asFailedWithReason:@"write_failed"];
        return;
    }

    [self markFilePath:filePath asCompleted:YES];
    [self trackInfo:@"bg_download_task_completed"
              value:@{@"filePath": filePath,
                      @"size_bytes": @(payload.length),
                      @"kind": kind}];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError * _Nullable)error {
    NSDictionary *meta = [self decodeTaskDescription:task.taskDescription];
    NSString *filePath = meta[kBgTaskFilePath];

    if (error != nil && filePath.length > 0) {
        // .cancelled errors come from cancelAndReset; nothing to record.
        if (error.code != NSURLErrorCancelled) {
            [self trackError:@"bg_download_task_failed"
                       value:@{@"filePath": filePath,
                               @"error": error.localizedDescription ?: @"unknown"}];
            [self markFilePath:filePath asFailedWithReason:@"task_error"];
        }
    }

    [self maybeFinalizeInstallation];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    [self maybeFinalizeInstallation];

    void (^handler)(void) = nil;
    @synchronized(self) {
        handler = self.systemCompletionHandler;
        self.systemCompletionHandler = nil;
    }
    if (handler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler();
        });
    }
}

#pragma mark - State mutation under serial queue

- (void)markFilePath:(NSString *)filePath asCompleted:(BOOL)completed {
    dispatch_sync(self.stateQueue, ^{
        NSMutableDictionary *state = [[self readPendingState] mutableCopy];
        if (state == nil) return;
        NSMutableSet *completedSet = [(state[kBgPendingCompletedTaskDescriptions] ?: [NSSet set]) mutableCopy];
        [completedSet addObject:filePath];
        state[kBgPendingCompletedTaskDescriptions] = completedSet;
        [self writePendingState:state];
    });
}

- (void)markFilePath:(NSString *)filePath asFailedWithReason:(NSString *)reason {
    dispatch_sync(self.stateQueue, ^{
        NSMutableDictionary *state = [[self readPendingState] mutableCopy];
        if (state == nil) return;
        NSMutableSet *failedSet = [(state[kBgPendingFailedTaskDescriptions] ?: [NSSet set]) mutableCopy];
        [failedSet addObject:filePath];
        state[kBgPendingFailedTaskDescriptions] = failedSet;
        [self writePendingState:state];
    });
}

#pragma mark - Finalization

- (void)maybeFinalizeInstallation {
    NSDictionary *state = [self readPendingState];
    if (state == nil) {
        return;
    }

    NSSet *expected = state[kBgPendingExpectedTaskDescriptions] ?: [NSSet set];
    NSSet *completed = state[kBgPendingCompletedTaskDescriptions] ?: [NSSet set];
    NSSet *failed = state[kBgPendingFailedTaskDescriptions] ?: [NSSet set];

    NSUInteger expectedCount = expected.count;
    NSUInteger settledCount = completed.count + failed.count;

    if (settledCount < expectedCount) {
        return;
    }

    NSDate *startedAt = state[kBgPendingStartedAt];
    NSTimeInterval timeTakenMs = startedAt ? -[startedAt timeIntervalSinceNow] * 1000 : 0;

    if (failed.count > 0) {
        [self trackError:@"bg_download_failed"
                   value:@{@"reason": @"task_failures",
                           @"failed_count": @(failed.count),
                           @"completed_count": @(completed.count),
                           @"time_taken_ms": @(timeTakenMs)}];
        [self cleanupAfterFailure];
        return;
    }

    NSData *manifestArchive = state[kBgPendingManifestArchive];
    AJPApplicationManifest *manifest = nil;
    if ([manifestArchive isKindOfClass:[NSData class]]) {
        NSError *unarchiveErr = nil;
        manifest = [NSKeyedUnarchiver unarchivedObjectOfClass:[AJPApplicationManifest class]
                                                     fromData:manifestArchive
                                                        error:&unarchiveErr];
    }
    if (manifest == nil) {
        [self trackError:@"bg_download_failed"
                   value:@{@"reason": @"manifest_unarchive_failed"}];
        [self cleanupAfterFailure];
        return;
    }

    // Commit canonical temp markers consumed by next cold launch's
    // handleTempPackageInstallation / handleTempResourcesInstallation.
    NSError *pkgWriteErr = nil;
    [self.fileUtil writeInstance:manifest.package
                        fileName:APP_PACKAGE_DATA_TEMP_FILE_NAME
                        inFolder:JUSPAY_MANIFEST_DIR
                           error:&pkgWriteErr];
    if (pkgWriteErr != nil) {
        [self trackError:@"bg_download_failed"
                   value:@{@"reason": @"package_temp_write_failed",
                           @"error": pkgWriteErr.localizedDescription ?: @"unknown"}];
        [self cleanupAfterFailure];
        return;
    }

    if (manifest.resources != nil) {
        NSError *resWriteErr = nil;
        [self.fileUtil writeInstance:manifest.resources
                            fileName:APP_TEMP_RESOURCES_DATA_FILE_NAME
                            inFolder:JUSPAY_MANIFEST_DIR
                               error:&resWriteErr];
        if (resWriteErr != nil) {
            [self trackError:@"bg_download_resources_temp_write_failed"
                       value:@{@"error": resWriteErr.localizedDescription ?: @"unknown"}];
            // Non-fatal: package marker is already written. Resources can be re-fetched
            // on next foreground RC fetch if needed.
        }
    }

    [self deletePendingState];
    [self.fileUtil deleteFile:APP_MANIFEST_DATA_TEMP_FILE_NAME inFolder:JUSPAY_MANIFEST_DIR error:nil];

    [self trackInfo:@"bg_download_session_finished"
              value:@{@"target_package_version": manifest.package.version ?: @"",
                      @"completed_count": @(completed.count),
                      @"time_taken_ms": @(timeTakenMs)}];

    // Note: we deliberately do NOT exit(0) here even when the app is in background.
    // App Store guideline 4.5.4 discourages programmatic termination, and iOS will
    // evict the suspended process under memory pressure on its own; the next
    // user-initiated cold launch consumes app-pkg-temp.dat via the existing
    // handleTempPackageInstallation path.
}

- (void)cleanupAfterFailure {
    [self deletePendingState];
    [self.fileUtil deleteFile:APP_MANIFEST_DATA_TEMP_FILE_NAME inFolder:JUSPAY_MANIFEST_DIR error:nil];
    [self clearPackageTempDirectory];
    [self clearResourcesTempDirectory];
}

#pragma mark - Inspect-only RC fetch (checkForUpdate)

- (void)inspectForUpdateWithCompletion:(void (^)(NSString *jsonResult))completion {
    NSString *baseline = [self installedVersionOnDisk];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *rcUrlKey = [NSString stringWithFormat:@"airborne.bg.%@.rcUrl", self.namespace];
    NSString *rcUrl = [defaults stringForKey:rcUrlKey];
    if (rcUrl.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([self updateCheckResultWithCurrent:baseline error:@"NO_PERSISTED_CONFIG"]);
        });
        return;
    }
    NSDictionary<NSString *, NSString *> *dimensions = [self readPersistedDimensions];
    NSString *fetchUrl = [self appendStickyTossToURL:rcUrl];

    [self fetchReleaseConfigFrom:fetchUrl
                      dimensions:dimensions
                         timeout:kBgOnDemandRcFetchTimeoutSeconds
                      completion:^(AJPApplicationManifest * _Nullable manifest, NSError * _Nullable error) {
        if (manifest == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self updateCheckResultWithCurrent:baseline
                                                        error:error.localizedDescription ?: @"RC_FETCH_FAILED"]);
            });
            return;
        }

        NSString *serverVersion = manifest.package.version ?: @"";
        BOOL mandatory = NO;
        id mandatoryValue = manifest.config.properties[@"mandatory"];
        if ([mandatoryValue isKindOfClass:[NSNumber class]]) {
            mandatory = [mandatoryValue boolValue];
        }
        BOOL available = baseline.length == 0 || ![baseline isEqualToString:serverVersion];

        NSDictionary *result = @{
            @"available":      @(available),
            @"currentVersion": baseline ?: @"",
            @"serverVersion":  serverVersion,
            @"mandatory":      @(mandatory)
        };
        NSString *jsonStr = [self jsonStringFromDictionary:result];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(jsonStr);
        });
    }];
}

- (NSString *)installedVersionOnDisk {
    // 1. Pending swap on disk wins — its version is what'll load on next cold launch.
    NSError *err = nil;
    id tempPkg = [self.fileUtil getDecodedInstanceForClass:[AJPApplicationPackage class]
                                     withContentOfFileName:APP_PACKAGE_DATA_TEMP_FILE_NAME
                                                  inFolder:JUSPAY_MANIFEST_DIR
                                                     error:&err];
    if ([tempPkg isKindOfClass:[AJPApplicationPackage class]]) {
        NSString *version = ((AJPApplicationPackage *)tempPkg).version;
        if (version.length > 0) {
            return version;
        }
    }

    // 2. Currently committed package on disk.
    AJPApplicationPackage *current = [self readCurrentPackage];
    if (current.version.length > 0) {
        return current.version;
    }

    // 3. Fall back to the consumer-bundled release_config.json. Mirrors Android's
    //    `loadedPackageVersion ?: releaseConfig?.pkg?.version ?: ""` baseline so a
    //    fresh install (no OTA committed yet) still reports the IPA-shipped version
    //    instead of an empty string that would always make the server look newer.
    NSData *bundledData = [self.fileUtil getFileDataFromBundle:@"release_config.json" error:nil];
    if (bundledData != nil) {
        AJPApplicationManifest *bundled = [[AJPApplicationManifest alloc] initWithData:bundledData error:nil];
        if (bundled.package.version.length > 0) {
            return bundled.package.version;
        }
    }
    return @"";
}

- (NSString *)updateCheckResultWithCurrent:(NSString *)current error:(NSString *)errorMsg {
    NSDictionary *result = @{
        @"available":      @NO,
        @"currentVersion": current ?: @"",
        @"serverVersion":  @"",
        @"mandatory":      @NO,
        @"error":          errorMsg ?: @"unknown"
    };
    return [self jsonStringFromDictionary:result];
}

- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&jsonErr];
    if (jsonData == nil) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
}

#pragma mark - Foreground download cycle (downloadUpdate)

- (void)startForegroundDownloadWithCompletion:(void (^)(BOOL success))completion {
    // Don't race against an in-flight push-driven download or an unconsumed swap.
    if (self.hasInflightDownload) {
        [self trackInfo:@"foreground_download_skipped" value:@{@"reason": @"bg_in_flight"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    NSString *pkgTempPath = [self.fileUtil fullPathInStorageForFilePath:APP_PACKAGE_DATA_TEMP_FILE_NAME
                                                               inFolder:JUSPAY_MANIFEST_DIR];
    if ([[NSFileManager defaultManager] fileExistsAtPath:pkgTempPath]) {
        [self trackInfo:@"foreground_download_skipped" value:@{@"reason": @"pending_swap_present"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *rcUrlKey = [NSString stringWithFormat:@"airborne.bg.%@.rcUrl", self.namespace];
    NSString *rcUrl = [defaults stringForKey:rcUrlKey];
    if (rcUrl.length == 0) {
        [self trackError:@"foreground_download_failed" value:@{@"reason": @"no_persisted_config"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }

    NSDictionary<NSString *, NSString *> *dimensions = [self readPersistedDimensions];
    NSString *fetchUrl = [self appendStickyTossToURL:rcUrl];

    [self fetchReleaseConfigFrom:fetchUrl
                      dimensions:dimensions
                         timeout:kBgOnDemandRcFetchTimeoutSeconds
                      completion:^(AJPApplicationManifest * _Nullable manifest, NSError * _Nullable error) {
        if (manifest == nil) {
            [self trackError:@"foreground_download_failed"
                       value:@{@"reason": @"rc_fetch_failed",
                               @"error": error.localizedDescription ?: @"unknown"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        AJPApplicationPackage *currentPackage = [self readCurrentPackage];
        AJPApplicationResources *currentResources = [self readCurrentResources];
        NSArray<AJPResource *> *importants = [self importantSplitsToDownloadFromNewPackage:manifest.package
                                                                           currentPackage:currentPackage];
        NSArray<AJPResource *> *resources = [self resourcesToDownloadFromNewResources:manifest.resources
                                                                    currentResources:currentResources];
        if (importants.count == 0 && resources.count == 0) {
            [self trackInfo:@"foreground_download_no_diff"
                      value:@{@"target_package_version": manifest.package.version ?: @""}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            return;
        }

        [self runForegroundDownloadsForManifest:manifest
                                     importants:importants
                                      resources:resources
                                     completion:completion];
    }];
}

- (void)runForegroundDownloadsForManifest:(AJPApplicationManifest *)manifest
                               importants:(NSArray<AJPResource *> *)importants
                                resources:(NSArray<AJPResource *> *)resources
                               completion:(void (^)(BOOL success))completion {
    [self clearPackageTempDirectory];
    [self.fileUtil createFolderIfDoesNotExist:[self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                                                 inFolder:JUSPAY_PACKAGE_DIR]];
    [self clearResourcesTempDirectory];
    [self.fileUtil createFolderIfDoesNotExist:[self.fileUtil fullPathInStorageForFilePath:JUSPAY_TEMP_DIR
                                                                                 inFolder:JUSPAY_RESOURCE_DIR]];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60;
    config.timeoutIntervalForResource = kBgForegroundTaskTimeoutSeconds;
    NSURLSession *fgSession = [NSURLSession sessionWithConfiguration:config];

    dispatch_group_t group = dispatch_group_create();
    NSLock *lock = [[NSLock alloc] init];
    __block BOOL anyFailed = NO;
    __block BOOL completed = NO;

    // Overall cycle cap. Mirrors Android `downloadUpdate(timeoutMs = 600_000L)`:
    // bound the entire RC-fetch + N-task download cycle so a stuck network can't
    // hang the JS Promise indefinitely. URLSession's `timeoutIntervalForResource`
    // only caps individual tasks — without this, N parallel slow downloads could
    // each ride up to the per-task limit before the cycle gives up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBgForegroundCycleTimeoutSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [lock lock];
        BOOL alreadyDone = completed;
        if (!alreadyDone) {
            anyFailed = YES;
        }
        [lock unlock];
        if (!alreadyDone) {
            [self trackError:@"foreground_download_failed" value:@{@"reason": @"cycle_timeout"}];
            // Cancels in-flight tasks; their completion handlers fire with
            // NSURLErrorCancelled, dispatch_group leaves drain, group_notify runs.
            [fgSession invalidateAndCancel];
        }
    });

    void (^downloadOne)(AJPResource *, NSString *) = ^(AJPResource *resource, NSString *kind) {
        if (resource.url == nil || resource.filePath.length == 0) {
            return;
        }
        dispatch_group_enter(group);
        NSURLRequest *request = [NSURLRequest requestWithURL:resource.url];
        NSURLSessionDataTask *task = [fgSession dataTaskWithRequest:request
                                                  completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            BOOL ok = NO;
            do {
                if (error != nil || data == nil) { break; }
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
                if (http != nil && (http.statusCode < 200 || http.statusCode >= 300)) { break; }
                if (resource.checksum.length > 0) {
                    NSString *computed = [AJPHelpers sha256ForData:data];
                    if (![computed.lowercaseString isEqualToString:resource.checksum.lowercaseString]) {
                        [self trackError:@"foreground_download_task_checksum_mismatch"
                                   value:@{@"filePath": resource.filePath,
                                           @"expected": resource.checksum,
                                           @"got": computed ?: @""}];
                        break;
                    }
                }
                // Sniff PK\x03\x04 and unwrap if zipped. Matches the foreground
                // AJPRemoteFileUtil.downloadFile contract — extension-agnostic.
                NSError *decompErr = nil;
                NSData *payload = [AJPHelpers maybeDecompressZip:data error:&decompErr];
                if (payload == nil) {
                    [self trackError:@"foreground_download_task_decompress_failed"
                               value:@{@"filePath": resource.filePath,
                                       @"error": decompErr.localizedDescription ?: @"unknown"}];
                    break;
                }
                NSString *folderName = [kind isEqualToString:kBgTaskKindResource] ? JUSPAY_RESOURCE_DIR : JUSPAY_PACKAGE_DIR;
                NSString *relativePath = [JUSPAY_TEMP_DIR stringByAppendingPathComponent:resource.filePath];
                NSString *destPath = [self.fileUtil fullPathInStorageForFilePath:relativePath inFolder:folderName];
                NSError *writeErr = nil;
                if (![payload writeToFile:destPath options:NSDataWritingAtomic error:&writeErr]) {
                    [self trackError:@"foreground_download_task_write_failed"
                               value:@{@"filePath": resource.filePath,
                                       @"error": writeErr.localizedDescription ?: @"unknown"}];
                    break;
                }
                ok = YES;
            } while (0);

            if (!ok) {
                [lock lock];
                anyFailed = YES;
                [lock unlock];
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    };

    for (AJPResource *split in importants) {
        downloadOne(split, kBgTaskKindPackage);
    }
    for (AJPResource *resource in resources) {
        downloadOne(resource, kBgTaskKindResource);
    }

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Mark complete BEFORE the cycle-timeout block can race in and double-invoke.
        [lock lock];
        completed = YES;
        [lock unlock];

        [fgSession finishTasksAndInvalidate];

        if (anyFailed) {
            [self trackError:@"foreground_download_failed" value:@{@"reason": @"task_failures"}];
            [self clearPackageTempDirectory];
            [self clearResourcesTempDirectory];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // Commit canonical temp markers consumed by next cold launch.
        NSError *pkgWriteErr = nil;
        [self.fileUtil writeInstance:manifest.package
                            fileName:APP_PACKAGE_DATA_TEMP_FILE_NAME
                            inFolder:JUSPAY_MANIFEST_DIR
                               error:&pkgWriteErr];
        if (pkgWriteErr != nil) {
            [self trackError:@"foreground_download_failed"
                       value:@{@"reason": @"package_temp_write_failed",
                               @"error": pkgWriteErr.localizedDescription ?: @"unknown"}];
            [self clearPackageTempDirectory];
            [self clearResourcesTempDirectory];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }
        if (manifest.resources != nil) {
            [self.fileUtil writeInstance:manifest.resources
                                fileName:APP_TEMP_RESOURCES_DATA_FILE_NAME
                                inFolder:JUSPAY_MANIFEST_DIR
                                   error:nil];
        }

        [self trackInfo:@"foreground_download_session_finished"
                  value:@{@"target_package_version": manifest.package.version ?: @""}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    });
}

- (NSDictionary<NSString *, NSString *> *)readPersistedDimensions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *dimsKey = [NSString stringWithFormat:@"airborne.bg.%@.dimensions", self.namespace];
    NSData *dimsData = [defaults dataForKey:dimsKey];
    if (dimsData != nil) {
        id parsed = [NSJSONSerialization JSONObjectWithData:dimsData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            return (NSDictionary *)parsed;
        }
    }
    return @{};
}

#pragma mark - Foreground RC fetch (within push budget)

- (void)fetchReleaseConfigFrom:(NSString *)urlString
                    dimensions:(NSDictionary<NSString *, NSString *> *)dimensions
                       timeout:(NSTimeInterval)timeoutSeconds
                    completion:(void (^)(AJPApplicationManifest * _Nullable manifest, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        completion(nil, [NSError errorWithDomain:@"in.juspay.Airborne" code:1 userInfo:@{NSLocalizedDescriptionKey: @"invalid url"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = timeoutSeconds;

    // Bypass any CDN/edge caching on the release-config endpoint — the whole
    // point of a check is to see what the server has *now*. Matches Android
    // `fetchLatestRCInternal` (ApplicationManager.kt:613).
    [request setValue:@"no-cache" forHTTPHeaderField:@"cache-control"];

    NSString *networkType = [AJPNetworkTypeDetector currentNetworkTypeString];
    if (networkType.length > 0) {
        [request setValue:networkType forHTTPHeaderField:@"x-network-type"];
    }
#if TARGET_OS_IOS
    [request setValue:[[UIDevice currentDevice] systemVersion] forHTTPHeaderField:@"x-os-version"];
#endif
    AJPApplicationPackage *currentPackage = [self readCurrentPackage];
    if (currentPackage.version.length > 0) {
        [request setValue:currentPackage.version forHTTPHeaderField:@"x-package-version"];
    }

    if (dimensions.count > 0) {
        // Sorted alphabetically so backend cache keys are stable across launches —
        // NSDictionary enumeration order is unspecified. Matches Android
        // `rcHeaders.toSortedMap()` (ApplicationManager.kt:615).
        NSArray<NSString *> *sortedKeys = [dimensions.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableString *dimsHeader = [NSMutableString string];
        for (NSString *field in sortedKeys) {
            [dimsHeader appendFormat:@"%@=%@;", field, dimensions[field]];
        }
        [request setValue:dimsHeader forHTTPHeaderField:@"x-dimension"];
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = timeoutSeconds;
    config.timeoutIntervalForResource = timeoutSeconds;
    NSURLSession *fgSession = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDataTask *task = [fgSession dataTaskWithRequest:request
                                              completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        [fgSession finishTasksAndInvalidate];
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (data == nil || data.length == 0) {
            completion(nil, [NSError errorWithDomain:@"in.juspay.Airborne" code:2 userInfo:@{NSLocalizedDescriptionKey: @"empty response"}]);
            return;
        }
        NSError *parseErr = nil;
        AJPApplicationManifest *manifest = [[AJPApplicationManifest alloc] initWithData:data error:&parseErr];
        if (manifest == nil) {
            completion(nil, parseErr ?: [NSError errorWithDomain:@"in.juspay.Airborne" code:3 userInfo:@{NSLocalizedDescriptionKey: @"manifest parse failed"}]);
            return;
        }
        completion(manifest, nil);
    }];
    [task resume];
}

#pragma mark - Sticky toss

- (NSString *)appendStickyTossToURL:(NSString *)urlString {
    if (urlString.length == 0) {
        return urlString;
    }
    NSString *tossKey = [NSString stringWithFormat:@"airborne.toss.%@", self.namespace];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *toss = [defaults stringForKey:tossKey];
    if (toss.length == 0) {
        toss = [[NSUUID UUID] UUIDString];
        [defaults setObject:toss forKey:tossKey];
    }
    NSString *encoded = [toss stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *separator = ([urlString rangeOfString:@"?"].location != NSNotFound) ? @"&" : @"?";
    return [NSString stringWithFormat:@"%@%@toss=%@", urlString, separator, encoded];
}

#pragma mark - Helpers

- (NSDictionary *)decodeTaskDescription:(NSString * _Nullable)taskDescription {
    if (taskDescription.length == 0) {
        return @{};
    }
    NSData *data = [taskDescription dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
}

@end
