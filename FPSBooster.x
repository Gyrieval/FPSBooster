#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

#define TARGET_FPS 120

static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_setFrameInterval = NULL;
static IMP orig_displayLinkWithTarget = NULL;
static IMP orig_addToRunLoop = NULL;
static IMP orig_setDrawableProperties = NULL;
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_nextDrawable = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;

static inline void lockLinkTo120(CADisplayLink *link) {
    if (!link) return;
    if (@available(iOS 15.0, *)) {
        CAFrameRateRange locked = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
        if (orig_setPreferredFrameRateRange) {
            ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(link, @selector(setPreferredFrameRateRange:), locked);
        }
    }
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(link, @selector(setPreferredFramesPerSecond:), TARGET_FPS);
    }
}

// 1. Khóa cứng 120 FPS cho CADisplayLink của game
static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    if (link) {
        if (!gameDisplayLinks) {
            gameDisplayLinks = [NSHashTable weakObjectsHashTable];
        }
        [gameDisplayLinks addObject:link];
        lockLinkTo120(link);
    }
    return link;
}

static void hooked_addToRunLoop(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    if (orig_addToRunLoop) {
        ((void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))orig_addToRunLoop)(self, _cmd, runloop, NSRunLoopCommonModes);
    }
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    lockLinkTo120((CADisplayLink *)self);
}

// 2. Tối ưu trực tiếp CAMetalLayer duy nhất của game (không tạo thêm view/layer thứ 2)
static void hooked_setDrawableProperties(id self, SEL _cmd, NSDictionary *props) {
    NSMutableDictionary *optProps = props ? [NSMutableDictionary dictionaryWithDictionary:props] : [NSMutableDictionary dictionary];
    optProps[@"EAGLDrawablePropertyRetainedBacking"] = @NO;
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(self, _cmd, optProps);
    }
}

static void hooked_metalLayoutSublayers(id self, SEL _cmd) {
    if (orig_metalLayoutSublayers) {
        ((void (*)(id, SEL))orig_metalLayoutSublayers)(self, _cmd);
    }
    if ([self isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)self;
        if ([metalLayer respondsToSelector:@selector(setPresentsWithTransaction:)]) {
            metalLayer.presentsWithTransaction = NO;
        }
        if ([metalLayer respondsToSelector:@selector(setFramebufferOnly:)]) {
            metalLayer.framebufferOnly = YES;
        }
        if ([metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) {
            metalLayer.maximumDrawableCount = 3;
        }
    }
}

// Đảm bảo mỗi lần game lấy khung hình tiếp theo, mọi DisplayLink vẫn đang khóa 120 FPS
static id hooked_nextDrawable(id self, SEL _cmd) {
    return ((id (*)(id, SEL))orig_nextDrawable)(self, _cmd);
}

// 3. Ngăn bóp xung do Low Power Mode hoặc nhiệt nhẹ
static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) {
    return NO;
}

static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    if (realState == NSProcessInfoThermalStateFair) {
        return NSProcessInfoThermalStateNominal;
    }
    return realState;
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        Class displayLinkClass = [CADisplayLink class];
        Method mCreate = class_getClassMethod(displayLinkClass, @selector(displayLinkWithTarget:selector:));
        if (mCreate) orig_displayLinkWithTarget = method_setImplementation(mCreate, (IMP)hooked_displayLinkWithTarget);

        Method mAddRunLoop = class_getInstanceMethod(displayLinkClass, @selector(addToRunLoop:forMode:));
        if (mAddRunLoop) orig_addToRunLoop = method_setImplementation(mAddRunLoop, (IMP)hooked_addToRunLoop);

        Method mFps = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (mFps) orig_setPreferredFramesPerSecond = method_setImplementation(mFps, (IMP)hooked_setPreferredFramesPerSecond);

        if (@available(iOS 15.0, *)) {
            Method mRange = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (mRange) orig_setPreferredFrameRateRange = method_setImplementation(mRange, (IMP)hooked_setPreferredFrameRateRange);
        }

        Method mInterval = class_getInstanceMethod(displayLinkClass, @selector(setFrameInterval:));
        if (mInterval) orig_setFrameInterval = method_setImplementation(mInterval, (IMP)hooked_setFrameInterval);

        Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
        if (eaglLayerClass) {
            Method mDrawProps = class_getInstanceMethod(eaglLayerClass, @selector(setDrawableProperties:));
            if (mDrawProps) orig_setDrawableProperties = method_setImplementation(mDrawProps, (IMP)hooked_setDrawableProperties);
        }

        Class metalLayerClass = [CAMetalLayer class];
        if (metalLayerClass) {
            Method mMetalLayout = class_getInstanceMethod(metalLayerClass, @selector(layoutSublayers));
            if (mMetalLayout) orig_metalLayoutSublayers = method_setImplementation(mMetalLayout, (IMP)hooked_metalLayoutSublayers);

            Method mNextDrawable = class_getInstanceMethod(metalLayerClass, @selector(nextDrawable));
            if (mNextDrawable) orig_nextDrawable = method_setImplementation(mNextDrawable, (IMP)hooked_nextDrawable);
        }

        Class processInfoClass = [NSProcessInfo class];
        Method mLowPower = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        Method mThermal = class_getInstanceMethod(processInfoClass, @selector(thermalState));
        if (mThermal) orig_thermalState = method_setImplementation(mThermal, (IMP)hooked_thermalState);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;

            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                for (CADisplayLink *link in gameDisplayLinks) {
                    lockLinkTo120(link);
                }
            }];
        });
    }
}
