#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import "ARC.h"
#import <stdlib.h>
#import <Block.h>
#import <dispatch/dispatch.h>

#pragma mark - Logging and Forwarding

//#define DEBUG
#ifdef DEBUG
#define ARC_LOG(fmt, ...) NSLog(@"[ARCShim] " fmt, ##__VA_ARGS__)
#else
#define ARC_LOG(fmt, ...)
#endif

id objc_msgSend_hack(id, SEL) __asm__("_objc_msgSend");

#pragma mark - Live Object Tracker

static CFMutableSetRef liveObjectSet;
static pthread_rwlock_t liveObjectLock = PTHREAD_RWLOCK_INITIALIZER;
static pthread_once_t weakTableOnce = PTHREAD_ONCE_INIT;

static void track_object_alloc(id obj) {
    pthread_rwlock_wrlock(&liveObjectLock);
    if (!liveObjectSet)
        liveObjectSet = CFSetCreateMutable(NULL, 0, NULL);
    CFSetAddValue(liveObjectSet, obj);
    pthread_rwlock_unlock(&liveObjectLock);
}

static void track_object_dealloc(id obj) {
    pthread_rwlock_wrlock(&liveObjectLock);
    if (liveObjectSet)
        CFSetRemoveValue(liveObjectSet, obj);
    pthread_rwlock_unlock(&liveObjectLock);
}

static bool is_valid_object(id obj) {
    if (!obj) return false;
    pthread_rwlock_rdlock(&liveObjectLock);
    bool exists = liveObjectSet && CFSetContainsValue(liveObjectSet, obj);
    pthread_rwlock_unlock(&liveObjectLock);
    return exists;
}

#pragma mark - Strong Reference Management

id objc_retain(id obj) {
    if (!obj) return nil;
    ARC_LOG("objc_retain(%p)", obj);
    return objc_msgSend_hack(obj, @selector(retain));
}

void objc_release(id obj) {
    if (!obj) return;
    if (!is_valid_object(obj)) {
        ARC_LOG("objc_release(%p) - SKIPPED: not tracked", obj);
    }
    ARC_LOG("objc_release(%p)", obj);
    objc_msgSend_hack(obj, @selector(release));
}

id objc_autorelease(id obj) {
    if (!obj) return nil;
    ARC_LOG("objc_autorelease(%p)", obj);
    return objc_msgSend_hack(obj, @selector(autorelease));
}

void objc_storeStrong(id *addr, id value) {
    if (!addr) return;
    id old = *addr;
    if (value == old) return;

    ARC_LOG("objc_storeStrong(%p, %p)", addr, value);
    if (value) objc_retain(value);
    *addr = value;
    if (old) objc_release(old);
}

#pragma mark - Autorelease Pool

void *objc_autoreleasePoolPush(void) {
    return (void *)[[NSAutoreleasePool alloc] init];
}

void objc_autoreleasePoolPop(void *pool) {
    NSAutoreleasePool *p = (NSAutoreleasePool *)pool;
    [p release];
}

#pragma mark - Weak Reference Support

static CFMutableDictionaryRef weakRecordMap;
static pthread_rwlock_t weakretainMapLock = PTHREAD_RWLOCK_INITIALIZER;
static char ARCShimSentinelKey;

@interface ARCShimWeakSentinel : NSObject
@property (nonatomic, assign) id target;
- (instancetype)initWithTarget:(id)target;
@end

@implementation ARCShimWeakSentinel
- (instancetype)initWithTarget:(id)target {
    if ((self = [super init])) {
        _target = target;
    }
    return self;
}

- (void)dealloc {
    id obj = _target;
    pthread_rwlock_wrlock(&weakretainMapLock);
    CFMutableSetRef slots = (CFMutableSetRef)CFDictionaryGetValue(weakRecordMap, (const void *)obj);
    if (slots) {
        CFIndex count = CFSetGetCount(slots);
        id *values = (id *)malloc(sizeof(id) * count);
        CFSetGetValues(slots, (const void **)values);
        for (CFIndex i = 0; i < count; i++) {
            id *slotPtr = (id *)values[i];
            objc_storeWeak(slotPtr, nil);
        }
        free(values);
        CFDictionaryRemoveValue(weakRecordMap, (const void *)obj);
    }
    pthread_rwlock_unlock(&weakretainMapLock);
    [super dealloc];
}
@end

static void weak_table_init(void) {
    CFDictionaryKeyCallBacks keyCallbacks = {0, NULL, NULL, NULL, NULL, NULL};
    CFDictionaryValueCallBacks valueCallbacks = kCFTypeDictionaryValueCallBacks;
    weakRecordMap = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &keyCallbacks,
        &valueCallbacks
    );
    pthread_rwlock_init(&weakretainMapLock, NULL);
}

static inline void ensureWeakTable() {
    pthread_once(&weakTableOnce, weak_table_init);
}

static void addSlotToRecord(id obj, id *slot) {
    if (!weakRecordMap) ensureWeakTable();
    pthread_rwlock_wrlock(&weakretainMapLock);
    CFMutableSetRef slots = (CFMutableSetRef)CFDictionaryGetValue(weakRecordMap, (const void *)obj);
    if (!slots) {
        slots = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(weakRecordMap, (const void *)obj, slots);
        CFRelease(slots);
        ARCShimWeakSentinel *sentinel = [[ARCShimWeakSentinel alloc] initWithTarget:obj];
        objc_setAssociatedObject(obj, &ARCShimSentinelKey, sentinel, OBJC_ASSOCIATION_RETAIN);
        [sentinel release];
        slots = (CFMutableSetRef)CFDictionaryGetValue(weakRecordMap, (const void *)obj);
    }
    CFSetAddValue(slots, slot);
    pthread_rwlock_unlock(&weakretainMapLock);
}

static void removeSlotFromRecord(id obj, id *slot) {
    if (!slot || !obj) return;
    if (!weakRecordMap) ensureWeakTable();

    pthread_rwlock_wrlock(&weakretainMapLock);
    CFMutableSetRef slots = (CFMutableSetRef)CFDictionaryGetValue(weakRecordMap, (const void *)obj);
    if (slots) {
        CFSetRemoveValue(slots, slot);
        if (CFSetGetCount(slots) == 0) {
            CFDictionaryRemoveValue(weakRecordMap, (const void *)obj);
        }
    }
    pthread_rwlock_unlock(&weakretainMapLock);

    *slot = nil;
}

id objc_initWeak(id *slot, id value) {
    ARC_LOG("objc_initWeak(%p, %p)", slot, value);
    *slot = value;
    if (value) addSlotToRecord(value, slot);
    return value;
}

void objc_destroyWeak(id *slot) {
    ARC_LOG("objc_destroyWeak(%p)", slot);
    id old = *slot;
    if (old) removeSlotFromRecord(old, slot);
    *slot = nil;
}

id objc_copyWeak(id *to, id *from) {
    ARC_LOG("objc_copyWeak(%p, %p)", to, from);
    id value = *from;
    *to = value;
    if (value) addSlotToRecord(value, to);
    return value;
}

id objc_storeWeak(id *slot, id value) {
    ARC_LOG("objc_storeWeak(%p, %p)", slot, value);
    if (!slot) return value;
    id old = *slot;
    if (old) removeSlotFromRecord(old, slot);
    *slot = value;
    if (value) addSlotToRecord(value, slot);
    return value;
}

id objc_loadWeakRetained(id *slot) {
    id value = *slot;
    if (value) objc_retain(value);
    return value;
}

#pragma mark - Block Support

id objc_retainBlock(id blk) {
    if (!blk) return nil;
    ARC_LOG("objc_retainBlock(%p)", blk);
    return (id)Block_copy(blk);
}

void objc_releaseBlock(id blk) {
    if (!blk) return;
    ARC_LOG("objc_releaseBlock(%p)", blk);
    Block_release(blk);
}

id objc_autoreleaseReturnValue(id obj) {
    return objc_autorelease(obj);
}

id objc_retainAutoreleasedReturnValue(id obj) {
    return objc_retain(obj);
}

id objc_retainAutoreleaseReturnValue(id obj) {
    return objc_autoreleaseReturnValue(objc_retain(obj));
}

id objc_retainAutorelease(id obj) {
    return objc_autorelease(objc_retain(obj));
}

#pragma mark - ARC Shim Initialization

__attribute__((weak)) void *(*_dispatch_begin_NSAutoReleasePool)(void);
__attribute__((weak)) void (*_dispatch_end_NSAutoReleasePool)(void *);

void __ARCShimInit(bool haveDispatch) {
    NSLog(@"ARCShim: Initializing...");
    pthread_rwlock_init(&liveObjectLock, NULL);
    weak_table_init();
    if (haveDispatch) {
		if (_dispatch_begin_NSAutoReleasePool != 0) {
			_dispatch_begin_NSAutoReleasePool = objc_autoreleasePoolPush;
		}
		if (_dispatch_end_NSAutoReleasePool != 0) {
			_dispatch_end_NSAutoReleasePool = objc_autoreleasePoolPop;
		}
    }
}

#pragma mark - NSObject Alloc/Dealloc Swizzling

@implementation NSObject (ARCShimTracker)

+ (id)arcshim_alloc {
    id obj = [self arcshim_alloc];
    ARC_LOG(@"alloc tracked: %p (%@)", obj, self);
    track_object_alloc(obj);
    return obj;
}

- (void)arcshim_dealloc {
    ARC_LOG(@"dealloc tracked: %p (%@)", self, [self class]);
    track_object_dealloc(self);
    [self arcshim_dealloc];
}

+ (void)load {
    static bool loaded = false;
    if (loaded != true) {
        method_exchangeImplementations(class_getClassMethod(self, @selector(alloc)),
                                        class_getClassMethod(self, @selector(arcshim_alloc)));
        method_exchangeImplementations(class_getInstanceMethod(self, @selector(dealloc)),
                                        class_getInstanceMethod(self, @selector(arcshim_dealloc)));
        loaded = true;
    }
}

@end
