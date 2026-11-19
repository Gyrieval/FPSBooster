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
static IMP orig_isLowPowerModeEnabled = NULL;

static NSHashTable *trackedDisplayLinks = nil;

static void applyTargetFpsToLink(CADisplayLink *link) {
    if (!link) return;
    if (@available(iOS 15.0, *)) {
        CAFrameRateRange range = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
        if (orig_setPreferredFrameRateRange) {
            ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(link, @selector(setPreferredFrameRateRange:), range);
        }
    }
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(link, @selector(setPreferredFramesPerSecond:), TARGET_FPS);
    }
}

// 1. Sửa lỗi __NSFrozenDictionaryM: Chỉ can thiệp vào mainBundle và dùng dictionaryWithDictionary:
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

// 2. Hook CADisplayLink để khóa tốc độ khung hình của OpenGL ES / Metal
static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    if (link) {
        if (!trackedDisplayLinks) trackedDisplayLinks = [NSHashTable weakObjectsHashTable];
        [trackedDisplayLinks addObject:link];
        applyTargetFpsToLink(link);
    }
    return link;
}

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    applyTargetFpsToLink((CADisplayLink *)self);
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    applyTargetFpsToLink((CADisplayLink *)self);
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

        // Hook CADisplayLink
        Class displayLinkClass = [CADisplayLink class];
        Method mCreate = class_getClassMethod(displayLinkClass, @selector(displayLinkWithTarget:selector:));
        if (mCreate) orig_displayLinkWithTarget = method_setImplementation(mCreate, (IMP)hooked_displayLinkWithTarget);

        Method mFps = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (mFps) orig_setPreferredFramesPerSecond = method_setImplementation(mFps, (IMP)hooked_setPreferredFramesPerSecond);

        if (@available(iOS 15.0, *)) {
            Method mRange = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (mRange) orig_setPreferredFrameRateRange = method_setImplementation(mRange, (IMP)hooked_setPreferredFrameRateRange);
        }

        // Hook NSProcessInfo
        Method mLowPower = class_getInstanceMethod([NSProcessInfo class], @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        // Giữ ưu tiên luồng & kiểm tra thông số DisplayLink định kỳ
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
                NSInteger activeLinks = 0;
                NSInteger currentPreferred = 0;
                for (CADisplayLink *link in trackedDisplayLinks) {
                    applyTargetFpsToLink(link);
                    activeLinks++;
                    currentPreferred = link.preferredFramesPerSecond;
                }

                NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                if (docsDir) {
                    NSString *log = [NSString stringWithFormat:@"Links: %ld | PreferredFPS: %ld | MaxScreenFPS: %ld\n",
                        (long)activeLinks, (long)currentPreferred, (long)[UIScreen mainScreen].maximumFramesPerSecond];
                    [log writeToFile:[docsDir stringByAppendingPathComponent:@"fps_status.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }];
        });
    }
}
