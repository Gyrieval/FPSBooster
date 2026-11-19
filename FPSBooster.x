#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

#define TARGET_FPS 120
#define TARGET_PACING_NS 7950000ULL
#define TARGET_RENDER_SCALE 1.5
// Đổi thành 0 nếu muốn ẩn thanh theo dõi FPS
#define ENABLE_FPS_OVERLAY 1

static IMP orig_objectForInfoDictionaryKey = NULL;
static IMP orig_infoDictionary = NULL;
static IMP orig_maxFramesPerSecond = NULL;
static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_setFrameInterval = NULL;
static IMP orig_displayLinkWithTarget = NULL;
static IMP orig_screenDisplayLinkWithTarget = NULL;
static IMP orig_addToRunLoop = NULL;
static IMP orig_setAnimationInterval = NULL;
static IMP orig_presentRenderbuffer = NULL;
static IMP orig_setDrawableProperties = NULL;
static IMP orig_eaglLayoutSublayers = NULL;
static IMP orig_eaglSetContentsScale = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static BOOL isBootComplete = NO;
static uint64_t nextFrameDeadlineTicks = 0;

// Biến đếm siêu nhẹ cho thanh HUD (chỉ cộng số nguyên mỗi frame)
static volatile uint32_t hudFrameCounter = 0;
static UIWindow *fpsHudWindow = nil;
static UILabel *fpsHudLabel = nil;
static uint64_t lastHudUpdateTicks = 0;

static inline mach_timebase_info_data_t getMachTimebase(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return timebase;
}

static inline uint64_t nsToMachTicks(uint64_t ns) {
    mach_timebase_info_data_t tb = getMachTimebase();
    return (ns * tb.denom) / tb.numer;
}

static inline double machTicksToMs(uint64_t ticks) {
    mach_timebase_info_data_t tb = getMachTimebase();
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e6;
}

static id hooked_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"] ||
        [key isEqualToString:@"CADisableMinimumFrameDuration"]) {
        return @YES;
    }
    return orig_objectForInfoDictionaryKey ? ((id (*)(id, SEL, NSString *))orig_objectForInfoDictionaryKey)(self, _cmd, key) : nil;
}

static NSDictionary *hooked_infoDictionary(id self, SEL _cmd) {
    if (!cachedPatchedInfoDict && orig_infoDictionary) {
        NSDictionary *origDict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
        if (origDict) {
            NSMutableDictionary *mut = [NSMutableDictionary dictionaryWithDictionary:origDict];
            mut[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
            mut[@"CADisableMinimumFrameDuration"] = @YES;
            cachedPatchedInfoDict = [mut copy];
        }
    }
    if (self == [NSBundle mainBundle] && cachedPatchedInfoDict) return cachedPatchedInfoDict;
    return orig_infoDictionary ? ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd) : nil;
}

static NSInteger hooked_maxFramesPerSecond(id self, SEL _cmd) {
    return TARGET_FPS;
}

static inline void lockLinkTo120(CADisplayLink *link) {
    if (!link) return;
    if (@available(iOS 15.0, *)) {
        CAFrameRateRange locked = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
        if (orig_setPreferredFrameRateRange) {
            ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(link, @selector(setPreferredFrameRateRange:), locked);
        }
    }
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(link, @selector(setPreferredFramesPerSecond:), TARGET_FPS);
    }
}

static void trackAndLockLink(CADisplayLink *link) {
    if (!link) return;
    if (!gameDisplayLinks) gameDisplayLinks = [NSHashTable weakObjectsHashTable];
    [gameDisplayLinks addObject:link];
    lockLinkTo120(link);
}

static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    trackAndLockLink(link);
    return link;
}

static CADisplayLink *hooked_screenDisplayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_screenDisplayLinkWithTarget)(self, _cmd, target, sel);
    trackAndLockLink(link);
    return link;
}

static void hooked_addToRunLoop(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    NSRunLoopMode targetMode = isBootComplete ? NSRunLoopCommonModes : mode;
    if (orig_addToRunLoop) {
        ((void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))orig_addToRunLoop)(self, _cmd, runloop, targetMode);
    }
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) { lockLinkTo120((CADisplayLink *)self); }
static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) { lockLinkTo120((CADisplayLink *)self); }
static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) { lockLinkTo120((CADisplayLink *)self); }

static void hooked_setAnimationInterval(id self, SEL _cmd, double interval) {
    if (orig_setAnimationInterval) {
        ((void (*)(id, SEL, double))orig_setAnimationInterval)(self, _cmd, (1.0 / 120.0));
    }
    for (CADisplayLink *link in gameDisplayLinks) lockLinkTo120(link);
}

static void primeEAGLLayerDynamicState(CALayer *layer) {
    if (!layer) return;
    Class eaglCls = NSClassFromString(@"CAEAGLLayer");
    if (!eaglCls || ![layer isKindOfClass:eaglCls]) return;

    if (layer.contentsScale > TARGET_RENDER_SCALE && orig_eaglSetContentsScale) {
        ((void (*)(id, SEL, CGFloat))orig_eaglSetContentsScale)(layer, @selector(setContentsScale:), TARGET_RENDER_SCALE);
    }
    @try {
        if ([layer respondsToSelector:NSSelectorFromString(@"setAsynchronous:")]) {
            [layer setValue:@YES forKey:@"asynchronous"];
        }
        if ([layer respondsToSelector:NSSelectorFromString(@"setPresentsWithTransaction:")]) {
            [layer setValue:@NO forKey:@"presentsWithTransaction"];
        }
        if ([layer respondsToSelector:NSSelectorFromString(@"setLowLatency:")]) {
            [layer setValue:@YES forKey:@"lowLatency"];
        }
    } @catch (NSException *e) {}
}

static void hooked_eaglSetContentsScale(id self, SEL _cmd, CGFloat scale) {
    CGFloat targetScale = (scale > TARGET_RENDER_SCALE) ? TARGET_RENDER_SCALE : scale;
    if (orig_eaglSetContentsScale) {
        ((void (*)(id, SEL, CGFloat))orig_eaglSetContentsScale)(self, _cmd, targetScale);
    }
}

static void hooked_eaglLayoutSublayers(id self, SEL _cmd) {
    if (orig_eaglLayoutSublayers) {
        ((void (*)(id, SEL))orig_eaglLayoutSublayers)(self, _cmd);
    }
    Class eaglCls = NSClassFromString(@"CAEAGLLayer");
    if (eaglCls && [self isKindOfClass:eaglCls]) {
        primeEAGLLayerDynamicState((CALayer *)self);
    }
}

static void hooked_setDrawableProperties(id self, SEL _cmd, NSDictionary *props) {
    NSMutableDictionary *optProps = props ? [NSMutableDictionary dictionaryWithDictionary:props] : [NSMutableDictionary dictionary];
    optProps[@"EAGLDrawablePropertyRetainedBacking"] = @NO;
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(self, _cmd, optProps);
    }
    primeEAGLLayerDynamicState((CALayer *)self);
}

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    if (isBootComplete) {
        uint64_t intervalTicks = nsToMachTicks(TARGET_PACING_NS);
        uint64_t now = mach_absolute_time();
        if (nextFrameDeadlineTicks == 0 || now > nextFrameDeadlineTicks + intervalTicks) {
            nextFrameDeadlineTicks = now + intervalTicks;
        } else {
            if (now < nextFrameDeadlineTicks) {
                mach_wait_until(nextFrameDeadlineTicks);
            }
            nextFrameDeadlineTicks += intervalTicks;
        }
    }

    BOOL res = orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
    [CATransaction flush];
    hudFrameCounter++;
    return res;
}

static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) { return NO; }
static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    return (realState == NSProcessInfoThermalStateFair) ? NSProcessInfoThermalStateNominal : realState;
}

static void setupFPSOverlayHUD(void) {
#if ENABLE_FPS_OVERLAY
    if (fpsHudWindow) return;

    UIWindowScene *activeScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }

    CGRect hudFrame = CGRectMake(54, 10, 92, 22);
    if (activeScene) {
        fpsHudWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        fpsHudWindow.frame = hudFrame;
    } else {
        fpsHudWindow = [[UIWindow alloc] initWithFrame:hudFrame];
    }

    fpsHudWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
    fpsHudWindow.userInteractionEnabled = NO;
    fpsHudWindow.backgroundColor = [UIColor clearColor];
    fpsHudWindow.opaque = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    fpsHudWindow.rootViewController = vc;

    fpsHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 92, 22)];
    fpsHudLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    fpsHudLabel.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.45 alpha:1.0];
    fpsHudLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
    fpsHudLabel.textAlignment = NSTextAlignmentCenter;
    fpsHudLabel.layer.cornerRadius = 6.0;
    fpsHudLabel.layer.masksToBounds = YES;
    fpsHudLabel.text = @"120.0 FPS";
    [vc.view addSubview:fpsHudLabel];

    fpsHudWindow.hidden = NO;
    lastHudUpdateTicks = mach_absolute_time();

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        uint64_t now = mach_absolute_time();
        uint32_t frames = hudFrameCounter;
        hudFrameCounter = 0;

        double elapsedMs = machTicksToMs(now - lastHudUpdateTicks);
        lastHudUpdateTicks = now;
        if (elapsedMs <= 0.0) return;

        double currentFps = (double)frames * 1000.0 / elapsedMs;
        if (currentFps > 120.0) currentFps = 120.0;

        if (currentFps >= 112.0) {
            fpsHudLabel.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.45 alpha:1.0];
        } else if (currentFps >= 85.0) {
            fpsHudLabel.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1.0];
        } else {
            fpsHudLabel.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
        }
        fpsHudLabel.text = [NSString stringWithFormat:@"%.1f FPS", currentFps];
    }];
#endif
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        Class bundleClass = [NSBundle class];
        Method mObjForKey = class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:));
        if (mObjForKey) orig_objectForInfoDictionaryKey = method_setImplementation(mObjForKey, (IMP)hooked_objectForInfoDictionaryKey);

        Method mInfoDict = class_getInstanceMethod(bundleClass, @selector(infoDictionary));
        if (mInfoDict) orig_infoDictionary = method_setImplementation(mInfoDict, (IMP)hooked_infoDictionary);

        Class screenClass = [UIScreen class];
        Method mMaxFps = class_getInstanceMethod(screenClass, @selector(maximumFramesPerSecond));
        if (mMaxFps) orig_maxFramesPerSecond = method_setImplementation(mMaxFps, (IMP)hooked_maxFramesPerSecond);

        Method mScreenDL = class_getInstanceMethod(screenClass, @selector(displayLinkWithTarget:selector:));
        if (mScreenDL) orig_screenDisplayLinkWithTarget = method_setImplementation(mScreenDL, (IMP)hooked_screenDisplayLinkWithTarget);

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

            Method mLayout = class_getInstanceMethod(eaglLayerClass, @selector(layoutSublayers));
            if (mLayout) orig_eaglLayoutSublayers = method_setImplementation(mLayout, (IMP)hooked_eaglLayoutSublayers);

            Method mScale = class_getInstanceMethod(eaglLayerClass, @selector(setContentsScale:));
            if (mScale) orig_eaglSetContentsScale = method_setImplementation(mScale, (IMP)hooked_eaglSetContentsScale);
        }

        Class eaglContextClass = NSClassFromString(@"EAGLContext");
        if (eaglContextClass) {
            Method mPresent = class_getInstanceMethod(eaglContextClass, @selector(presentRenderbuffer:));
            if (mPresent) orig_presentRenderbuffer = method_setImplementation(mPresent, (IMP)hooked_presentRenderbuffer);
        }

        Class processInfoClass = [NSProcessInfo class];
        Method mLowPower = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        Method mThermal = class_getInstanceMethod(processInfoClass, @selector(thermalState));
        if (mThermal) orig_thermalState = method_setImplementation(mThermal, (IMP)hooked_thermalState);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Class directorCallerClass = NSClassFromString(@"CCDirectorCaller");
            if (directorCallerClass) {
                Method mAnimInt = class_getInstanceMethod(directorCallerClass, NSSelectorFromString(@"setAnimationInterval:"));
                if (mAnimInt) orig_setAnimationInterval = method_setImplementation(mAnimInt, (IMP)hooked_setAnimationInterval);
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isBootComplete = YES;
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            for (CADisplayLink *link in gameDisplayLinks) lockLinkTo120(link);
            setupFPSOverlayHUD();
        });
    }
}
