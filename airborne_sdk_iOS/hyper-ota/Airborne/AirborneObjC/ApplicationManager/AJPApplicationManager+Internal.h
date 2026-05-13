//
//  AJPApplicationManager+Internal.h
//  Airborne
//
//  Copyright © Juspay Technologies. All rights reserved.
//
//  Internal-only category exposing helpers that the SDK's background-download
//  coordinator needs but that aren't part of the public framework surface.
//

#ifndef AJPApplicationManager_Internal_h
#define AJPApplicationManager_Internal_h

#import <Foundation/Foundation.h>

#if SWIFT_PACKAGE
#import "AJPApplicationManager.h"
#import "AJPResource.h"
#else
#import <Airborne/AJPApplicationManager.h>
#import <Airborne/AJPResource.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface AJPApplicationManager (Internal)

/// Pure predicate used to decide whether a resource needs (re)downloading by
/// comparing URLs and checksums. Identical semantics to the existing instance
/// method; exposed as a class method so callers without a manager instance
/// (e.g. the silent-push background coordinator) can reuse the diff logic.
+ (BOOL)shouldDownloadResource:(AJPResource * _Nullable)resourceToBeDownloaded
              existingResource:(AJPResource * _Nullable)existingResource;

@end

NS_ASSUME_NONNULL_END

#endif /* AJPApplicationManager_Internal_h */
