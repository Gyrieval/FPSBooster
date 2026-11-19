#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

#define TARGET_FPS 120

static IMP orig_infoDictionary = NULL;
static IMP orig_objectForInfoDictionaryKey = NULL;
static IMP orig_displayLinkWithTarget = NULL;
static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_setFrameInterval = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;

static NSHashTable *trackedDisplayLinks = nil;
static CADisplayLink *enforcerLink = nil;

static inline void forceLockDisplayLink(CADisplayLink *link) {
    if (!link || link == enforcerLink) return;

    if (@available(iOS 15.0, *)) {
        CAFrameRateRange range = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
        if (orig_setPreferredFrameRateRange) {
            ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(link, @selector(setPreferredFrameRateRange:), range);
        }
    }
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(link, @selector(setPreferredFramesPerSecond:), TARGET_FPS);
    }
    if (orig_setFrameInterval) {
        ((void (*)(id, SEL, NSInteger))orig_setFrameInterval)(link, @selector(setFrameInterval:), 1);
    }
}

// Đối tượng nhận nhịp mỗi khung hình để làm mới khóa FPS liên tục
@interface FPSContinuousEnforcer : NSObject
- (void)onFrame:(CADisplayLink *)sender;
@end

@implementation FPSContinuousEnforcer
- (void)onFrame:(CADisplayLink *)sender {
    for (CADisplayLink *link in trackedDisplayLinks) {
        forceLockDisplayLink(link);
    }
}
@end

static FPSContinuousEnforcer *enforcerTarget = nil;

// 1. Tiêm CADisableMinimumFrameDurationOnPhone = YES an toàn trong RAM
static NSDictionary *hooked_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
    if (self == [NSBundle mainBundle] && [dict isKindOfClass:[NSDictionary class]]) {
        if (![dict[@"CADisableMinimumFrameDurationOnPhone"] boolValue]) {
            NSMutableDictionary *safeMutable = [NSMutableDictionary dictionaryWithDictionary:dict];
            safeMutable[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
            return [safeMutable copy];
        }
    }
    return dict;
}

static id hooked_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"]) {
        return @YES;
    }
    return ((id (*)(id, SEL, NSString *))orig_objectForInfoDictionaryKey)(self, _cmd, key);
}

// 2. Bắt mọi CADisplayLink được tạo ra
static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    if (link && target != enforcerTarget) {
        if (!trackedDisplayLinks) {
            trackedDisplayLinks = [NSHashTable weakObjectsHashTable];
        }
        [trackedDisplayLinks addObject:link];
        forceLockDisplayLink(link);
    }
    return link;
}

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    forceLockDisplayLink((CADisplayLink *)self);
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    forceLockDisplayLink((CADisplayLink *)self);
}

static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    forceLockDisplayLink((CADisplayLink *)self);
}

// 3. Chặn Low Power Mode
static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) {
    return NO;
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        // Hook NSBundle
        Class bundleClass = [NSBundle class];
        Method mInfoDict = class_getInstanceMethod(bundleClass, @selector(infoDictionary));
        if (mInfoDict) orig_infoDictionary = method_setImplementation(mInfoDict, (IMP)hooked_infoDictionary);

        Method mObjForKey = class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:));
        if (mObjForKey) orig_objectForInfoDictionaryKey = method_setImplementation(mObjForKey, (IMP)hooked_objectForInfoDictionaryKey);

        // Hook CADisplayLink (bao gồm cả setFrameInterval: cũ của Cocos2d-x)
        Class displayLinkClass = [CADisplayLink class];
        Method mCreate = class_getClassMethod(displayLinkClass, @selector(displayLinkWithTarget:selector:));
        if (mCreate) orig_displayLinkWithTarget = method_setImplementation(mCreate, (IMP)hooked_displayLinkWithTarget);

        Method mFps = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (mFps) orig_setPreferredFramesPerSecond = method_setImplementation(mFps, (IMP)hooked_setPreferredFramesPerSecond);

        if (@available(iOS 15.0, *)) {
            Method mRange = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (mRange) orig_setPreferredFrameRateRange = method_setImplementation(mRange, (IMP)hooked_setPreferredFrameRateRange);
        }

        Method mInterval = class_getInstanceMethod(displayLinkClass, @selector(setFrameInterval:));
        if (mInterval) orig_setFrameInterval = method_setImplementation(mInterval, (IMP)hooked_setFrameInterval);

        // Hook NSProcessInfo
        Method mLowPower = class_getInstanceMethod([NSProcessInfo class], @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        // Khởi tạo vòng lặp làm mới FPS liên tục theo từng khung hình (per-frame)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;

            enforcerTarget = [[FPSContinuousEnforcer alloc] init];
            enforcerLink = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(
                [CADisplayLink class], @selector(displayLinkWithTarget:selector:), enforcerTarget, @selector(onFrame:)
            );

            if (@available(iOS 15.0, *)) {
                CAFrameRateRange maxRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
                if (orig_setPreferredFrameRateRange) {
                    ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(enforcerLink, @selector(setPreferredFrameRateRange:), maxRange);
                }
            }
            if (orig_setPreferredFramesPerSecond) {
                ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(enforcerLink, @selector(setPreferredFramesPerSecond:), TARGET_FPS);
            }
            [enforcerLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
    }
}
