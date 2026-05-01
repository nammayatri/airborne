
#import "Airborne.h"

@interface Airborne() <AirborneDelegate>

@property (nonatomic, strong) NSString* namespace;
@property (nonatomic, strong) AirborneServices* airborne;
@property (nonatomic, weak) id <AirborneDelegate> delegate;

@end

@implementation Airborne

static NSMutableDictionary<NSString *, Airborne *> *_airborneInstances = nil;
static dispatch_queue_t _airborneSyncQueue = nil;

static void AirborneEnsureRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _airborneInstances = [NSMutableDictionary dictionary];
        _airborneSyncQueue = dispatch_queue_create("in.juspay.Airborne.singleton", DISPATCH_QUEUE_CONCURRENT);
    });
}

+ (instancetype)sharedInstanceWithNamespace:(NSString *)aNamespace {
    AirborneEnsureRegistry();

    __block Airborne *instance = nil;

    // Read existing instance (concurrent)
    dispatch_sync(_airborneSyncQueue, ^{
        instance = _airborneInstances[aNamespace];
    });

    if (instance == nil) {
        // Write new instance (barrier to prevent concurrent writes)
        dispatch_barrier_sync(_airborneSyncQueue, ^{
            if (!_airborneInstances[aNamespace]) {
                _airborneInstances[aNamespace] = [[self alloc] initWithNamespace:aNamespace];
            }
            instance = _airborneInstances[aNamespace];
        });
    }

    return instance;
}

- (instancetype)initWithNamespace:(NSString *)namespace {
    self = [super init];
    if (self) {
        self.namespace = namespace;
    }
    return self;
}

- (instancetype)initWithReleaseConfigURL:(NSString *)releaseConfigURL delegate:(id<AirborneDelegate>)delegate {
    self = [super init];
    if (self) {
        self.airborne = [[AirborneServices alloc] initWithReleaseConfigURL:releaseConfigURL delegate:delegate ?: self];
        NSString *ns = ([delegate respondsToSelector:@selector(namespace)] ? [delegate namespace] : nil) ?: @"default";
        self.namespace = ns;
        AirborneEnsureRegistry();
        dispatch_barrier_sync(_airborneSyncQueue, ^{
            _airborneInstances[ns] = self;
        });
    }
    return self;
}

- (NSString *)getBundlePath {
    return [self.airborne getIndexBundlePath].absoluteString;
}

- (NSString *)getFileContent:(NSString *)filePath {
    return [self.airborne getFileContentAtPath:filePath];
}

- (NSString *)getReleaseConfig {
    return [self.airborne getReleaseConfig];
}

#pragma mark - AirborneDelegate

- (NSString *)namespace {
    return @"default";
}

@end

