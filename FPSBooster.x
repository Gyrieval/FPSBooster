#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

#define TARGET_FPS 120
#define TARGET_PACING_NS 8280000ULL

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
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static BOOL isBootComplete = NO;
static uint64_t nextFrameDeadlineTicks = 0;

// Hệ thống ghi log bất đồng bộ
static NSString *logFilePath = nil;
static dispatch_queue_t logWriteQueue = nil;
static NSInteger frameCount = 0;
static NSInteger presentCount = 0;
static double accumVsyncDeltaMs = 0.0;
static double accumPresentMs = 0.0;
static CFTimeInterval lastVsyncTimestamp = 0.0;

static double statMeasuredFPS = 0.0;
static double statPresentFPS = 0.0;
static double statAvgVsyncDeltaMs = 0.0;
static double statAvgPresentCostMs = 0.0;
static uint64_t lastStatTicks = 0;

static void writeDebugLog(NSString *message) {
    if (!logFilePath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            logFilePath = [paths[0] stringByAppendingPathComponent:@"fps_debug.log"];
        }
    }
    if (!logFilePath) return;
    if (!logWriteQueue) {
        logWriteQueue = dispatch_queue_create("com.fpsbooster.logqueue", DISPATCH_QUEUE_SERIAL);
    }

    NSDate *now = [NSDate date];
    NSString *targetPath = [logFilePath copy];
    NSString *msgCopy = [message copy];

    dispatch_async(logWriteQueue, ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm:ss.SSS"];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:now], msgCopy];

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:targetPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:targetPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
}

static inline mach_timebase_info_data_t getMachTimebase(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return timebase;
}

static inline double machTicksToMs(uint64_t ticks) {
    mach_timebase_info_data_t tb = getMachTimebase();
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e6;
}

static inline uint64_t nsToMachTicks(uint64_t ns) {
    mach_timebase_info_data_t tb = getMachTimebase();
    return (ns * tb.denom) / tb.numer;
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

static void hooked_doCaller(id self, SEL _cmd, id sender) {
    if ([sender isKindOfClass:[CADisplayLink class]]) {
        CADisplayLink *dl = (CADisplayLink *)sender;
        if (lastVsyncTimestamp > 0.0 && dl.timestamp > lastVsyncTimestamp) {
            accumVsyncDeltaMs += (dl.timestamp - lastVsyncTimestamp) * 1000.0;
        }
        lastVsyncTimestamp = dl.timestamp;
    }

    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }

    uint64_t now = mach_absolute_time();
    frameCount++;
    if (lastStatTicks == 0) {
        lastStatTicks = now;
    } else {
        double elapsedMs = machTicksToMs(now - lastStatTicks);
        if (elapsedMs >= 1000.0) {
            statMeasuredFPS = (double)frameCount * 1000.0 / elapsedMs;
            statPresentFPS = (double)presentCount * 1000.0 / elapsedMs;
            statAvgVsyncDeltaMs = (frameCount > 0) ? (accumVsyncDeltaMs / (double)frameCount) : 0.0;
            statAvgPresentCostMs = (presentCount > 0) ? (accumPresentMs / (double)presentCount) : 0.0;

            // Hiệu chỉnh lại pha mỗi giây để giữ chuỗi 118-120 FPS không trôi pha
            nextFrameDeadlineTicks = 0;

            frameCount = 0;
            presentCount = 0;
            accumVsyncDeltaMs = 0.0;
            accumPresentMs = 0.0;
            lastStatTicks = now;
        }
    }
}

// Auto-Reset Pacing 8.28ms + Single Flush (giữ 118-120 FPS liên tục không trôi pha)
static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t t0 = mach_absolute_time();
    glFlush();

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
    uint64_t t1 = mach_absolute_time();

    presentCount++;
    accumPresentMs += machTicksToMs(t1 - t0);
    return res;
}

static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) { return NO; }
static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    return (realState == NSProcessInfoThermalStateFair) ? NSProcessInfoThermalStateNominal : realState;
}

static void dumpDiagnosticLog(void) {
    NSMutableArray *linksInfo = [NSMutableArray array];
    for (CADisplayLink *link in gameDisplayLinks) {
        double hz = (link.duration > 0) ? (1.0 / link.duration) : 0.0;
        [linksInfo addObject:[NSString stringWithFormat:@"[paused:%d, hz:%.1f]", link.isPaused, hz]];
    }

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"=== BÁO CÁO AUTO-RESET PACING 118-120HZ + LOG ===\n"];
    [msg appendFormat:@"- Nhịp doCaller: %.1f FPS | Khoảng cách VSync TB: %.2f ms (120Hz = 8.33ms, 80Hz = 12.50ms)\n", statMeasuredFPS, statAvgVsyncDeltaMs];
    [msg appendFormat:@"- Tốc độ xuất hình GPU: %.1f FPS (Trung bình: %.2f ms/lệnh)\n", statPresentFPS, statAvgPresentCostMs];
    [msg appendFormat:@"- Trạng thái DisplayLinks: %@\n", [linksInfo componentsJoinedByString:@", "]];
    [msg appendString:@"=================================================="];
    writeDebugLog(msg);
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            logFilePath = [paths[0] stringByAppendingPathComponent:@"fps_debug.log"];
            [[NSFileManager defaultManager] removeItemAtPath:logFilePath error:nil];
        }
        writeDebugLog(@"Khởi động FPSBooster (Auto-Reset Pacing 118-120Hz + Async Log)...");

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

                Method mDoCaller = class_getInstanceMethod(directorCallerClass, NSSelectorFromString(@"doCaller:"));
                if (mDoCaller) orig_doCaller = method_setImplementation(mDoCaller, (IMP)hooked_doCaller);
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isBootComplete = YES;
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            for (CADisplayLink *link in gameDisplayLinks) lockLinkTo120(link);

            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                dumpDiagnosticLog();
            }];
        });
    }
}
