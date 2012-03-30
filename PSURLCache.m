//
//  PSURLCache.m
//  PSKit
//
//  Created by Peter Shih on 3/10/11.
//  Copyright (c) 2011 Peter Shih.. All rights reserved.
//

#import "PSURLCache.h"

typedef void (^PSURLCacheNetworkBlock)(void);

// This encodes a given URL into a file system safe string
static inline NSString * PSURLCacheKeyWithURL(NSURL *URL) {
    // NOTE: If the URL is extremely long, the path becomes too long for the file system to handle and it fails
    return [[URL absoluteString] stringFromMD5Hash];
//    return [(NSString *)CFURLCreateStringByAddingPercentEscapes(NULL,
//                                                               (CFStringRef)[URL absoluteString],
//                                                               NULL,
//                                                               (CFStringRef)@"!*'();:@&=+$,/?%#[]",
//                                                               kCFStringEncodingUTF8) autorelease];
}

@interface PSURLCache ()

@property (nonatomic, retain) NSOperationQueue *networkQueue;
@property (nonatomic, retain) NSOperationQueue *responseQueue;
@property (nonatomic, retain) NSMutableArray *pendingOperations;

// Retrieves the corresponding directory for a cache type
- (NSString *)cacheDirectoryPathForCacheType:(PSURLCacheType)cacheType;

// Retrieves a file system path for a given URL and cache type
- (NSString *)cachePathForURL:(NSURL *)URL cacheType:(PSURLCacheType)cacheType;

@end


@implementation PSURLCache

@synthesize
networkQueue = _networkQueue,
responseQueue = _responseQueue,
pendingOperations = _pendingOperations;

+ (id)sharedCache {
    static id sharedCache;
    if (!sharedCache) {
        sharedCache = [[self alloc] init];
    }
    return sharedCache;
}

- (id)init {
    self = [super init];
    if (self) {
        self.networkQueue = [[[NSOperationQueue alloc] init] autorelease];
        self.networkQueue.maxConcurrentOperationCount = 4;
        
        self.responseQueue = [[[NSOperationQueue alloc] init] autorelease];
        self.responseQueue.maxConcurrentOperationCount = 4;
        
        self.pendingOperations = [NSMutableArray array];
        
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(resume) 
                                                     name:kPSURLCacheDidIdle 
                                                   object:self];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kPSURLCacheDidIdle object:self];
    self.networkQueue = nil;
    self.responseQueue = nil;
    self.pendingOperations = nil;
    [super dealloc];
}

#pragma mark - Queue
- (void)resume {    
    // Reverse the order of pending operations before adding them back into the queue
    NSInteger i = 0;
    NSInteger j = [self.pendingOperations count] - 1;
    while (i < j) {
        [self.pendingOperations exchangeObjectAtIndex:i withObjectAtIndex:j];
        i++;
        j--;
    }
    
    [self.pendingOperations enumerateObjectsUsingBlock:^(id networkBlock, NSUInteger idx, BOOL *stop) {
        [self.networkQueue addOperationWithBlock:networkBlock];
    }];
    [self.pendingOperations removeAllObjects];
    [self.networkQueue setSuspended:NO];
}

- (void)suspend {
    [self.networkQueue setSuspended:YES];
    [[NSNotificationQueue defaultQueue] enqueueNotification:[NSNotification 
                                                             notificationWithName:kPSURLCacheDidIdle object:self] 
                                               postingStyle:NSPostWhenIdle];
}

#pragma mark - Cache
// Write to Cache
- (void)cacheData:(NSData *)data URL:(NSURL *)URL cacheType:(PSURLCacheType)cacheType {
    if (!data || !URL) return;
    
    NSURL *cachedURL = [[URL copy] autorelease];
    NSString *cachePath = [self cachePathForURL:cachedURL cacheType:cacheType];
    [data writeToFile:cachePath atomically:YES];
}

// Read from Cache
- (void)loadURL:(NSURL *)URL cacheType:(PSURLCacheType)cacheType usingCache:(BOOL)usingCache completionBlock:(void (^)(NSData *cachedData, NSURL *cachedURL, BOOL isCached, NSError *error))completionBlock {
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL method:@"GET" headers:nil parameters:nil];
    
    [self loadRequest:request cacheType:cacheType usingCache:usingCache completionBlock:completionBlock];
}

- (void)loadRequest:(NSMutableURLRequest *)request cacheType:(PSURLCacheType)cacheType usingCache:(BOOL)usingCache completionBlock:(void (^)(NSData *cachedData, NSURL *cachedURL, BOOL isCached, NSError *error))completionBlock {
    
    NSURL *cachedURL = [[request.URL copy] autorelease];
    NSString *cachePath = [self cachePathForURL:cachedURL cacheType:cacheType];
    NSData *data = [NSData dataWithContentsOfFile:cachePath];
    
    if (data && usingCache) {
        completionBlock(data, cachedURL, YES, nil);
    } else {
        PSURLCacheNetworkBlock networkBlock = ^(void){
            [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidStartNotification object:self];
            [NSURLConnection sendAsynchronousRequest:request 
                                               queue:self.responseQueue 
                                   completionHandler:^(NSURLResponse *response, NSData *cachedData, NSError *error) {
                                       // This is in the background
                                      [self cacheData:cachedData URL:cachedURL cacheType:cacheType];
                                       [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                                           [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidFinishNotification object:self];
                                           completionBlock(cachedData, cachedURL, NO, error);
                                       }];
                                   }];
        };
             
        // Queue up a network request
        if (self.networkQueue.isSuspended) {
            [self.pendingOperations addObject:Block_copy(networkBlock)];
            Block_release(networkBlock);
        } else {
            [self.networkQueue addOperationWithBlock:networkBlock];
        }
    }
}

#pragma mark - Cache Path
- (NSString *)cacheDirectoryPathForCacheType:(PSURLCacheType)cacheType {
    NSString *cacheBaseDirectory = (cacheType == PSURLCacheTypeSession) ? NSTemporaryDirectory() : (NSString *)[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    
    
    NSString *cacheDirectoryPath = [cacheBaseDirectory stringByAppendingPathComponent:NSStringFromClass([self class])];
    
    // Creates directory if necessary
    BOOL isDir = NO;
    NSError *error;
    if (![[NSFileManager defaultManager] fileExistsAtPath:cacheDirectoryPath isDirectory:&isDir] && isDir == NO) {
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectoryPath 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:&error];
    }
    
    return cacheDirectoryPath;
}

- (NSString *)cachePathForURL:(NSURL *)URL cacheType:(PSURLCacheType)cacheType {
    NSString *cacheDirectoryPath = [self cacheDirectoryPathForCacheType:cacheType];
    
    NSString *cacheKey = PSURLCacheKeyWithURL(URL);
    NSString *cachePath = [cacheDirectoryPath stringByAppendingPathComponent:cacheKey];
    
    return cachePath;
}

#pragma mark - Purge Cache
- (void)purgeCacheWithCacheType:(PSURLCacheType)cacheType {
    NSString *cacheDirectoryPath = [self cacheDirectoryPathForCacheType:cacheType];
    
    // Removes and recreates directory
    BOOL isDir = NO;
    NSError *error;
    if ([[NSFileManager defaultManager] fileExistsAtPath:cacheDirectoryPath isDirectory:&isDir] && isDir == YES) {
        [[NSFileManager defaultManager] removeItemAtPath:cacheDirectoryPath error:&error];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectoryPath 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:&error];
    }
}

@end
