#import "AirborneReact.h"
#import "Airborne.h"
#import <React/RCTLog.h>
#import <Airborne/AJPApplicationManager.h>
#import <Airborne/Airborne-Swift.h>

@implementation AirborneReact

RCT_EXPORT_MODULE(Airborne)

static NSString * const defaultNamespace = @"default";

+ (void)initializeAirborneWithReleaseConfigUrl:(NSString *)releaseConfigUrl {
    [self initializeAirborneWithReleaseConfigUrl:releaseConfigUrl inNamespace:defaultNamespace];
}

+ (void)initializeAirborneWithReleaseConfigUrl:(NSString *)releaseConfigUrl inNamespace:ns {
    AJPApplicationManager* manager = [AJPApplicationManager getSharedInstanceWithWorkspace:ns delegate:nil logger:nil];
}

+ (void)initializeAirborneWithReleaseConfigUrl:(NSString *)releaseConfigUrl delegate:delegate {
    AJPApplicationManager* manager = [AJPApplicationManager getSharedInstanceWithWorkspace:defaultNamespace delegate:delegate logger:nil];
}

+ (void)initializeAirborneWithReleaseConfigUrl:(NSString *)releaseConfigUrl inNamespace:ns delegate:delegate {
    AJPApplicationManager* manager = [AJPApplicationManager getSharedInstanceWithWorkspace:ns delegate:delegate logger:nil];
}

#ifdef RCT_NEW_ARCH_ENABLED
- (void)readReleaseConfig:(NSString *)nameSpace
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *config = [[AirborneInstance sharedInstanceWithNamespace:ns] getReleaseConfig];
        resolve(config);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)getFileContent:(NSString *)nameSpace
              filePath:(NSString *)filePath
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *content = [[AirborneInstance sharedInstanceWithNamespace:ns] getFileContent:filePath];
        resolve(content);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)getBundlePath:(NSString *)nameSpace
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *bundlePath = [[AirborneInstance sharedInstanceWithNamespace:ns] getBundlePath];
        resolve(bundlePath);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)checkForUpdate:(NSString *)nameSpace
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"checkForUpdate is not implemented on iOS", nil);
}

- (void)downloadUpdate:(NSString *)nameSpace
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"downloadUpdate is not implemented on iOS", nil);
}

- (void)startBackgroundDownload:(NSString *)nameSpace
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"startBackgroundDownload is not implemented on iOS", nil);
}

- (void)reloadApp:(NSString *)nameSpace
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"reloadApp is not implemented on iOS", nil);
}

- (void)hasPendingBundleUpdate:(NSString *)nameSpace
                       resolve:(RCTPromiseResolveBlock)resolve
                        reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"hasPendingBundleUpdate is not implemented on iOS", nil);
}
#else
RCT_EXPORT_METHOD(readReleaseConfig:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *config = [[AirborneInstance sharedInstanceWithNamespace:ns] getReleaseConfig];
        resolve(config);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(getFileContent:(NSString *)nameSpace
                  filePath:(NSString *)filePath
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *content = [[AirborneInstance sharedInstanceWithNamespace:ns] getFileContent:filePath];
        resolve(content);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(getBundlePath:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *ns = (nameSpace.length > 0) ? nameSpace : defaultNamespace;
        NSString *bundlePath = [[AirborneInstance sharedInstanceWithNamespace:ns] getBundlePath];
        resolve(bundlePath);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(checkForUpdate:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"checkForUpdate is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(downloadUpdate:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"downloadUpdate is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(startBackgroundDownload:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"startBackgroundDownload is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(reloadApp:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"reloadApp is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(hasPendingBundleUpdate:(NSString *)nameSpace
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"hasPendingBundleUpdate is not implemented on iOS", nil);
}
#endif

#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeAirborneSpecJSI>(params);
}
#endif

@end
