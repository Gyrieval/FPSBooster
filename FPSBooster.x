#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
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

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static BOOL isBootComplete = NO;
static NSString *logFilePath = nil;

// Biến đo hiệu năng chi tiết từng khung hình
static NSInteger frameCount = 0;
static double accumCpuFrameMs = 0.0;
static double accumPresentMs = 0.0;
static double accumVsyncDeltaMs = 0.0;
static CFTimeInterval lastVsyncTimestamp = 0.0;

static double statMeasuredFPS = 0.0;
static double statAvgCpuMs = 0.0;
static double statAvgPresentMs = 0.0;
static double statAvgVsyncDeltaMs = 0.0;
static uint64_t lastStatTicks = 0;

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

// 2. Khóa nhịp CADisplayLink gốc ở 120 FPS
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
    if (!gameDisplayLinks) {
        gameDisplayLinks = [NSHashTable weakObjectsHashTable];
    }
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
    for (CADisplayLink *link in gameDisplayLinks) {
        lockLinkTo120(link);
    }
}

// 3. Đo thời gian thực thi từng khung hình CPU & VSync Timestamp
static void hooked_doCaller(id self, SEL _cmd, id sender) {
    if ([sender isKindOfClass:[CADisplayLink class]]) {
        CADisplayLink *dl = (CADisplayLink *)sender;
        if (lastVsyncTimestamp > 0.0 && dl.timestamp > lastVsyncTimestamp) {
            accumVsyncDeltaMs += (dl.timestamp - lastVsyncTimestamp) * 1000.0;
        }
        lastVsyncTimestamp = dl.timestamp;
    }

    uint64_t t0 = mach_absolute_time();
    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }
    uint64_t t1 = mach_absolute_time();

    frameCount++;
    accumCpuFrameMs += machTicksToMs(t1 - t0);

    if (lastStatTicks == 0) {
        lastStatTicks = t1;
    } else {
        double elapsedMs = machTicksToMs(t1 - lastStatTicks);
        if (elapsedMs >= 1000.0) {
            statMeasuredFPS = (double)frameCount * 1000.0 / elapsedMs;
            statAvgCpuMs = (frameCount > 0) ? (accumCpuFrameMs / (double)frameCount) : 0.0;
            statAvgPresentMs = (frameCount > 0) ? (accumPresentMs / (double)frameCount) : 0.0;
            statAvgVsyncDeltaMs = (frameCount > 0) ? (accumVsyncDeltaMs / (double)frameCount) : 0.0;

            frameCount = 0;
            accumCpuFrameMs = 0.0;
            accumPresentMs = 0.0;
            accumVsyncDeltaMs = 0.0;
            lastStatTicks = t1;
        }
    }
}

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t t0 = mach_absolute_time();
    BOOL res = orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
    uint64_t t1 = mach_absolute_time();
    accumPresentMs += machTicksToMs(t1 - t0);
    return res;
}

// 4. Tối ưu VRAM & giữ Triple Buffering
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

static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) { return NO; }

static NSProcessInfoThermalState hooked_thermalState(id self, SEL _cmd) {
    NSProcessInfoThermalState realState = ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)(self, _cmd);
    return (realState == NSProcessInfoThermalStateFair) ? NSProcessInfoThermalStateNominal : realState;
}

// Hàm quét cấu trúc Layer của UIWindow & kiểm tra Info.plist vật lý
static void dumpFourLayerDiagnostics(void) {
    // Kiểm tra Info.plist vật lý thực sự trên ổ đĩa của MainBundle (bỏ qua hook)
    NSString *plistPath = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
    NSDictionary *diskPlist = plistPath ? [NSDictionary dictionaryWithContentsOfFile:plistPath] : nil;
    id diskKeyVal = diskPlist[@"CADisableMinimumFrameDurationOnPhone"];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];

    // Quét tất cả sublayer trong KeyWindow để xem game đang vẽ lên CAEAGLLayer hay CAMetalLayer
    NSMutableArray *layerSummary = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                NSMutableArray *queue = [NSMutableArray arrayWithObject:w.layer];
                while (queue.count > 0) {
                    CALayer *curr = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    NSString *clsName = NSStringFromClass([curr class]);
                    if ([clsName containsString:@"EAGL"] || [clsName containsString:@"Metal"]) {
                        BOOL asyncPresent = NO;
                        if ([curr respondsToSelector:@selector(presentsWithTransaction)]) {
                            asyncPresent = !((CAMetalLayer *)curr).presentsWithTransaction;
                        }
                        [layerSummary addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f, async:%d)",
                                                 clsName, curr.bounds.size.width, curr.bounds.size.height, asyncPresent]];
                    }
                    if (curr.sublayers) [queue addObjectsFromArray:curr.sublayers];
                }
            }
        }
    }

    NSProcessInfoThermalState realThermal = orig_thermalState ? ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)([NSProcessInfo processInfo], @selector(thermalState)) : 0;
    BOOL realLPM = orig_isLowPowerModeEnabled ? ((BOOL (*)(id, SEL))orig_isLowPowerModeEnabled)([NSProcessInfo processInfo], @selector(isLowPowerModeEnabled)) : NO;

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"=== CHẨN ĐOÁN 4 TẦNG (DISK PLIST + VSYNC + CPU/GPU) ===\n"];
    [msg appendFormat:@"- FPS thực tế: %.1f FPS | Khoảng cách VSync TB: %.2f ms (120Hz = 8.33ms, 80Hz = 12.50ms)\n", statMeasuredFPS, statAvgVsyncDeltaMs];
    [msg appendFormat:@"- Thời gian CPU xử lý 1 frame: %.2f ms (trong đó presentRenderbuffer: %.2f ms)\n", statAvgCpuMs, statAvgPresentMs];
    [msg appendFormat:@"- BundleID: %@ | Disk Info.plist Key: %@ (Path: %@)\n", bundleId, diskKeyVal ?: @"KHÔNG CÓ", plistPath.lastPathComponent];
    [msg appendFormat:@"- Thermal thật: %ld | LowPower thật: %d | DisplayLinks: %lu\n", (long)realThermal, realLPM, (unsigned long)gameDisplayLinks.count];
    [msg appendFormat:@"- Đồ họa Layer đang hiển thị: %@\n", [layerSummary componentsJoinedByString:@", "]];
    [msg appendString:@"======================================================="];
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
        writeDebugLog(@"Khởi động FPSBooster 4-Layer Diagnostic...");

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
            isBootComplete = YES;
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            for (CADisplayLink *link in gameDisplayLinks) {
                lockLinkTo120(link);
            }

            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                dumpFourLayerDiagnostics();
            }];
        });
    }
}
