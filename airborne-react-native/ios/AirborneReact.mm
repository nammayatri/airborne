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
- (void)readReleaseConfig:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *config = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getReleaseConfig];
        resolve(config);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)getFileContent:(NSString *)filePath
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *content = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getFileContent:filePath];
        resolve(content);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)getBundlePath:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject {
    @try {
        NSString *bundlePath = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getBundlePath];
        resolve(bundlePath);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

- (void)checkForUpdate:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"checkForUpdate is not implemented on iOS", nil);
}

- (void)downloadUpdate:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"downloadUpdate is not implemented on iOS", nil);
}

- (void)startBackgroundDownload:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"startBackgroundDownload is not implemented on iOS", nil);
}

- (void)reloadApp:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"reloadApp is not implemented on iOS", nil);
}

- (void)hasPendingBundleUpdate:(RCTPromiseResolveBlock)resolve
                        reject:(RCTPromiseRejectBlock)reject {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"hasPendingBundleUpdate is not implemented on iOS", nil);
}
#else
RCT_EXPORT_METHOD(readReleaseConfig:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *config = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getReleaseConfig];
        resolve(config);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(getFileContent:(NSString *)filePath
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *content = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getFileContent:filePath];
        resolve(content);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(getBundlePath:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        NSString *bundlePath = [[Airborne sharedInstanceWithNamespace:defaultNamespace] getBundlePath];
        resolve(bundlePath);
    } @catch (NSException *exception) {
        reject(@"AIRBORNE_ERROR", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(checkForUpdate:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"checkForUpdate is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(downloadUpdate:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"downloadUpdate is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(startBackgroundDownload:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"startBackgroundDownload is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(reloadApp:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    reject(@"AIRBORNE_NOT_IMPLEMENTED_IOS", @"reloadApp is not implemented on iOS", nil);
}

RCT_EXPORT_METHOD(hasPendingBundleUpdate:(RCTPromiseResolveBlock)resolve
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
