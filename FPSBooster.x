#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <mach/mach_time.h>

#define TARGET_FPS 120

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
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *directorDisplayLinks = nil;
static __weak id activeDirectorCaller = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static dispatch_source_t precision120HzTimer = nil;
static BOOL isPrecisionTimerActive = NO;

// Biến ghi log thuần túy (không can thiệp luồng chạy)
static NSString *logFilePath = nil;
static NSInteger timerTickCount = 0;
static NSInteger doCallerCount = 0;
static NSInteger presentCount = 0;
static double measuredTimerHz = 0.0;
static double measuredDoCallerHz = 0.0;
static double measuredPresentFPS = 0.0;
static double avgPresentCostMs = 0.0;
static double accumulatedPresentMs = 0.0;
static uint64_t lastSampleTicks = 0;

static void writeDebugLog(NSString *message) {
    if (!logFilePath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            logFilePath = [paths[0] stringByAppendingPathComponent:@"fps_debug.log"];
        }
    }
    if (!logFilePath) return;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], message];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static inline double machTicksToMs(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return (double)ticks * (double)timebase.numer / (double)timebase.denom / 1e6;
}

static void updateCounters(void) {
    uint64_t now = mach_absolute_time();
    if (lastSampleTicks == 0) {
        lastSampleTicks = now;
        return;
    }
    double elapsedMs = machTicksToMs(now - lastSampleTicks);
    if (elapsedMs >= 1000.0) {
        measuredTimerHz = (double)timerTickCount * 1000.0 / elapsedMs;
        measuredDoCallerHz = (double)doCallerCount * 1000.0 / elapsedMs;
        measuredPresentFPS = (double)presentCount * 1000.0 / elapsedMs;
        avgPresentCostMs = (presentCount > 0) ? (accumulatedPresentMs / (double)presentCount) : 0.0;

        timerTickCount = 0;
        doCallerCount = 0;
        presentCount = 0;
        accumulatedPresentMs = 0.0;
        lastSampleTicks = now;
    }
}

// 1. Giả lập Info.plist trong RAM
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
    if (self == [NSBundle mainBundle] && cachedPatchedInfoDict) {
        return cachedPatchedInfoDict;
    }
    return orig_infoDictionary ? ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd) : nil;
}

static NSInteger hooked_maxFramesPerSecond(id self, SEL _cmd) {
    return TARGET_FPS;
}

// 2. Quản lý CADisplayLink & chuyển giao nhịp sang Precision 120Hz Timer
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

static void handleNewDisplayLink(CADisplayLink *link, id target, SEL sel) {
    if (!link) return;
    lockLinkTo120(link);

    NSString *targetClass = NSStringFromClass([target class]);
    if ([targetClass isEqualToString:@"CCDirectorCaller"]) {
        activeDirectorCaller = target;
        if (!directorDisplayLinks) {
            directorDisplayLinks = [NSHashTable weakObjectsHashTable];
        }
        [directorDisplayLinks addObject:link];
        if (isPrecisionTimerActive) {
            link.paused = YES;
        }
    }
}

static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    handleNewDisplayLink(link, target, sel);
    return link;
}

static CADisplayLink *hooked_screenDisplayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_screenDisplayLinkWithTarget)(self, _cmd, target, sel);
    handleNewDisplayLink(link, target, sel);
    return link;
}

static void hooked_addToRunLoop(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    NSRunLoopMode targetMode = isPrecisionTimerActive ? NSRunLoopCommonModes : mode;
    if (orig_addToRunLoop) {
        ((void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))orig_addToRunLoop)(self, _cmd, runloop, targetMode);
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

static void hooked_setAnimationInterval(id self, SEL _cmd, double interval) {
    if (orig_setAnimationInterval) {
        ((void (*)(id, SEL, double))orig_setAnimationInterval)(self, _cmd, (1.0 / 120.0));
    }
    if (isPrecisionTimerActive) {
        for (CADisplayLink *link in directorDisplayLinks) {
            link.paused = YES;
        }
    }
}

static void hooked_doCaller(id self, SEL _cmd, id sender) {
    activeDirectorCaller = self;
    doCallerCount++;
    updateCounters();
    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }
}

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t t0 = mach_absolute_time();
    BOOL res = orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
    uint64_t t1 = mach_absolute_time();

    presentCount++;
    accumulatedPresentMs += machTicksToMs(t1 - t0);
    updateCounters();
    return res;
}

static void startPrecision120HzDriver(void) {
    if (precision120HzTimer) return;
    isPrecisionTimerActive = YES;

    for (CADisplayLink *link in directorDisplayLinks) {
        link.paused = YES;
    }

    uint64_t intervalNs = (uint64_t)(1000000000ULL / TARGET_FPS);
    precision120HzTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(precision120HzTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, 0);

    dispatch_source_set_event_handler(precision120HzTimer, ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        timerTickCount++;
        updateCounters();
        id caller = activeDirectorCaller;
        if (caller && orig_doCaller) {
            ((void (*)(id, SEL, id))orig_doCaller)(caller, @selector(doCaller:), nil);
        }
    });

    dispatch_resume(precision120HzTimer);
}

// 3. Tối ưu VRAM & giữ Triple Buffering
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
        if ([metalLayer respondsToSelector:@selector(setPresentsWithTransaction:)]) metalLayer.presentsWithTransaction = NO;
        if ([metalLayer respondsToSelector:@selector(setFramebufferOnly:)]) metalLayer.framebufferOnly = YES;
        if ([metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) metalLayer.maximumDrawableCount = 3;
    }
}

// 4. Chặn điều tiết năng lượng & cảnh báo nhiệt
static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) { return NO; }

static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    return (realState == NSProcessInfoThermalStateFair) ? NSProcessInfoThermalStateNominal : realState;
}

static void dumpVerificationLog(void) {
    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"=== KIỂM TRA HOẠT ĐỘNG PRECISION 120HZ TIMER ===\n"];
    [msg appendFormat:@"- Nhịp Timer bắn: %.1f Hz | CCDirectorCaller::doCaller: %.1f Hz\n", measuredTimerHz, measuredDoCallerHz];
    [msg appendFormat:@"- Lệnh presentRenderbuffer: %.1f FPS (Thời gian trung bình mỗi lệnh: %.2f ms)\n", measuredPresentFPS, avgPresentCostMs];
    [msg appendFormat:@"- Trạng thái Timer: %@ | Số DisplayLink đang tạm dừng: %lu\n",
     isPrecisionTimerActive ? @"ĐANG CHẠY" : @"CHƯA CHẠY", (unsigned long)directorDisplayLinks.count];
    [msg appendString:@"================================================"];
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
        writeDebugLog(@"Khởi động FPSBooster (Chế độ ghi log kiểm tra, giữ nguyên logic)...");

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
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            startPrecision120HzDriver();

            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                dumpVerificationLog();
            }];
        });
    }
}
