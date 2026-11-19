#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

#define TARGET_FPS 120
// Chu kỳ chính xác tuyệt đối của 120.0 Hz: 1,000,000,000 / 120 = 8,333,333 ns
#define FRAME_INTERVAL_NS 8333333ULL
#define MAX_HISTORY_SECONDS 3600

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
static IMP orig_doCaller = NULL;
static IMP orig_presentRenderbuffer = NULL;
static IMP orig_setDrawableProperties = NULL;
static IMP orig_eaglLayoutSublayers = NULL;
static IMP orig_eaglSetContentsScale = NULL;
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static BOOL isBootComplete = NO;

// Bộ điều phối 120Hz độc lập (Self-Driven Mach Timer)
static __weak id activeDirectorCaller = nil;
static dispatch_source_t highPrecision120HzTimer = nil;
static BOOL isAppActive = YES;
static uint64_t lastDoCallerTicks = 0;

// Bộ đệm RAM thuần C
static double fpsHistory[MAX_HISTORY_SECONDS];
static int historyCount = 0;
static uint32_t secondFrameCount = 0;
static uint64_t secondStartTicks = 0;
static uint64_t totalSessionFrames = 0;
static uint64_t sessionStartTicks = 0;

static inline mach_timebase_info_data_t getMachTimebase(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return timebase;
}

static inline double machTicksToMs(uint64_t ticks) {
    mach_timebase_info_data_t tb = getMachTimebase();
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e6;
}

static void flushRamSummaryToFile(void) {
    if (totalSessionFrames == 0 || sessionStartTicks == 0) return;

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    NSString *summaryPath = [paths[0] stringByAppendingPathComponent:@"fps_summary.txt"];

    uint64_t now = mach_absolute_time();
    double totalSec = machTicksToMs(now - sessionStartTicks) / 1000.0;
    double avgFps = (totalSec > 0.0) ? ((double)totalSessionFrames / totalSec) : 0.0;

    double minFps = 999.0;
    double maxFps = 0.0;
    for (int i = 0; i < historyCount; i++) {
        if (fpsHistory[i] < minFps) minFps = fpsHistory[i];
        if (fpsHistory[i] > maxFps) maxFps = fpsHistory[i];
    }
    if (historyCount == 0) {
        minFps = avgFps;
        maxFps = avgFps;
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"=== TÓM TẮT HIỆU NĂNG SELF-DRIVEN 120HZ (%@) ===\n", [fmt stringFromDate:[NSDate date]]];
    [report appendFormat:@"- Thời gian đo: %.1f giây | Tổng khung hình: %llu\n", totalSec, totalSessionFrames];
    [report appendFormat:@"- FPS Trung bình: %.1f FPS | Thấp nhất: %.1f FPS | Cao nhất: %.1f FPS\n", avgFps, minFps, maxFps];
    [report appendString:@"- Chi tiết từng giây (FPS): "];

    for (int i = 0; i < historyCount; i++) {
        [report appendFormat:@"%.1f%s", fpsHistory[i], (i < historyCount - 1) ? ", " : "\n"];
    }
    [report appendString:@"========================================================\n"];

    [report writeToFile:summaryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

static void startSelfDriven120HzTimer(void) {
    if (highPrecision120HzTimer) return;
    highPrecision120HzTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
    dispatch_source_set_timer(highPrecision120HzTimer, dispatch_time(DISPATCH_TIME_NOW, 0), FRAME_INTERVAL_NS, 100000ULL);
    dispatch_source_set_event_handler(highPrecision120HzTimer, ^{
        if (!isBootComplete || !isAppActive) return;
        id caller = activeDirectorCaller;
        if (caller && orig_doCaller) {
            uint64_t now = mach_absolute_time();
            // Chỉ bắn khung hình nếu khoảng cách đủ >= 7.8 ms (tránh vẽ chồng 2 lần trong cùng 1 nhịp)
            if (lastDoCallerTicks == 0 || machTicksToMs(now - lastDoCallerTicks) >= 7.8) {
                lastDoCallerTicks = now;
                ((void (*)(id, SEL, id))orig_doCaller)(caller, NSSelectorFromString(@"doCaller:"), nil);
            }
        }
    });
    dispatch_resume(highPrecision120HzTimer);
}

static void hooked_doCaller(id self, SEL _cmd, id sender) {
    activeDirectorCaller = self;
    if (isBootComplete) {
        // Khi timer 120Hz đã tiếp quản, bỏ qua xung 96Hz thừa từ CADisplayLink để không bị loạn nhịp
        if (sender != nil && highPrecision120HzTimer != nil) {
            return;
        }
    }
    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }
}

static void hooked_setAnimationInterval(id self, SEL _cmd, double interval) {
    activeDirectorCaller = self;
    if (orig_setAnimationInterval) {
        ((void (*)(id, SEL, double))orig_setAnimationInterval)(self, _cmd, (1.0 / 120.0));
    }
    for (CADisplayLink *link in gameDisplayLinks) lockLinkTo120(link);
}

static void primeEAGLLayerDynamicState(CALayer *layer) {
    if (!layer) return;
    if (layer.contentsScale > 2.0 && orig_eaglSetContentsScale) {
        ((void (*)(id, SEL, CGFloat))orig_eaglSetContentsScale)(layer, @selector(setContentsScale:), 2.0);
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
    CGFloat targetScale = (scale > 2.0) ? 2.0 : scale;
    if (orig_eaglSetContentsScale) {
        ((void (*)(id, SEL, CGFloat))orig_eaglSetContentsScale)(self, _cmd, targetScale);
    }
}

static void hooked_eaglLayoutSublayers(id self, SEL _cmd) {
    if (orig_eaglLayoutSublayers) {
        ((void (*)(id, SEL))orig_eaglLayoutSublayers)(self, _cmd);
    }
    primeEAGLLayerDynamicState((CALayer *)self);
}

static void hooked_setDrawableProperties(id self, SEL _cmd, NSDictionary *props) {
    NSMutableDictionary *optProps = props ? [NSMutableDictionary dictionaryWithDictionary:props] : [NSMutableDictionary dictionary];
    optProps[@"EAGLDrawablePropertyRetainedBacking"] = @NO;
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(self, _cmd, optProps);
    }
    primeEAGLLayerDynamicState((CALayer *)self);
}

static void hooked_metalLayoutSublayers(id self, SEL _cmd) {
    if (orig_metalLayoutSublayers) {
        ((void (*)(id, SEL))orig_metalLayoutSublayers)(self, _cmd);
    }
    if ([self isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)self;
        if ([metalLayer respondsToSelector:@selector(setPresentsWithTransaction:)]) metalLayer.presentsWithTransaction = NO;
        if ([metalLayer respondsToSelector:@selector(setFramebufferOnly:)]) metalLayer.framebufferOnly = YES;
        if ([metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) metalLayer.maximumDrawableCount = 3;
    }
}

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    glFlush();
    BOOL res = orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
    [CATransaction flush];

    if (isBootComplete) {
        uint64_t tDone = mach_absolute_time();
        if (sessionStartTicks == 0) {
            sessionStartTicks = tDone;
            secondStartTicks = tDone;
        }
        totalSessionFrames++;
        secondFrameCount++;

        double secElapsedMs = machTicksToMs(tDone - secondStartTicks);
        if (secElapsedMs >= 1000.0) {
            if (historyCount < MAX_HISTORY_SECONDS) {
                fpsHistory[historyCount++] = (double)secondFrameCount * 1000.0 / secElapsedMs;
            }
            secondFrameCount = 0;
            secondStartTicks = tDone;
        }
    }

    return res;
}

static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) { return NO; }
static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    return (realState == NSProcessInfoThermalStateFair) ? NSProcessInfoThermalStateNominal : realState;
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

        Class metalLayerClass = [CAMetalLayer class];
        if (metalLayerClass) {
            Method mMetalLayout = class_getInstanceMethod(metalLayerClass, @selector(layoutSublayers));
            if (mMetalLayout) orig_metalLayoutSublayers = method_setImplementation(mMetalLayout, (IMP)hooked_metalLayoutSublayers);
        }

        Class processInfoClass = [NSProcessInfo class];
        Method mLowPower = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        Method mThermal = class_getInstanceMethod(processInfoClass, @selector(thermalState));
        if (mThermal) orig_thermalState = method_setImplementation(mThermal, (IMP)hooked_thermalState);

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            isAppActive = NO;
            flushRamSummaryToFile();
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            isAppActive = YES;
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Class directorCallerClass = NSClassFromString(@"CCDirectorCaller");
            if (directorCallerClass) {
                Method mAnimInt = class_getInstanceMethod(directorCallerClass, NSSelectorFromString(@"setAnimationInterval:"));
                if (mAnimInt) orig_setAnimationInterval = method_setImplementation(mAnimInt, (IMP)hooked_setAnimationInterval);

                Method mDoCaller = class_getInstanceMethod(directorCallerClass, NSSelectorFromString(@"doCaller:"));
                if (mDoCaller) orig_doCaller = method_setImplementation(mDoCaller, (IMP)hooked_doCaller);
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isBootComplete = YES;
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            for (CADisplayLink *link in gameDisplayLinks) lockLinkTo120(link);
            startSelfDriven120HzTimer();
        });
    }
}
