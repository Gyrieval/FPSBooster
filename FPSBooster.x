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
static IMP orig_addToRunLoop = NULL;
static IMP orig_setAnimationInterval = NULL;
static IMP orig_setDrawableProperties = NULL;
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_presentRenderbuffer = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static NSString *logFilePath = nil;
static BOOL isBootComplete = NO;

// Biến đo đạc hiệu năng
static uint64_t lastMeasureTime = 0;
static NSInteger presentedFramesCount = 0;
static double measuredRealFPS = 0.0;
static NSInteger directorCallerTickCount = 0;
static double measuredDirectorFPS = 0.0;
static uint64_t lastDirectorMeasureTime = 0;

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
    if (orig_objectForInfoDictionaryKey) {
        return ((id (*)(id, SEL, NSString *))orig_objectForInfoDictionaryKey)(self, _cmd, key);
    }
    return nil;
}

static NSDictionary *hooked_infoDictionary(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        if (!cachedPatchedInfoDict && orig_infoDictionary) {
            NSDictionary *origDict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
            if (origDict) {
                NSMutableDictionary *mut = [NSMutableDictionary dictionaryWithDictionary:origDict];
                mut[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
                mut[@"CADisableMinimumFrameDuration"] = @YES;
                cachedPatchedInfoDict = [mut copy];
            }
        }
        if (cachedPatchedInfoDict) return cachedPatchedInfoDict;
    }
    return orig_infoDictionary ? ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd) : nil;
}

static NSInteger hooked_maxFramesPerSecond(id self, SEL _cmd) {
    return TARGET_FPS;
}

// 2. Khóa nhịp 120 FPS (TUYỆT ĐỐI KHÔNG invalidate DisplayLink của game)
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

static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    if (link) {
        if (!gameDisplayLinks) gameDisplayLinks = [NSHashTable weakObjectsHashTable];
        [gameDisplayLinks addObject:link];
        lockLinkTo120(link);
    }
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

// Đo số lần CCDirectorCaller::doCaller: được gọi mỗi giây (để biết DisplayLink bắn bao nhiêu nhịp/giây)
static IMP orig_doCaller = NULL;
static void hooked_doCaller(id self, SEL _cmd, id sender) {
    uint64_t now = mach_absolute_time();
    directorCallerTickCount++;
    if (lastDirectorMeasureTime == 0) {
        lastDirectorMeasureTime = now;
    } else {
        double elapsed = machTicksToMs(now - lastDirectorMeasureTime);
        if (elapsed >= 1000.0) {
            measuredDirectorFPS = (double)directorCallerTickCount * 1000.0 / elapsed;
            directorCallerTickCount = 0;
            lastDirectorMeasureTime = now;
        }
    }
    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }
}

// 3. Đo tốc độ xuất hình thực tế tại EAGLContext
static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t now = mach_absolute_time();
    presentedFramesCount++;
    if (lastMeasureTime == 0) {
        lastMeasureTime = now;
    } else {
        double elapsedMs = machTicksToMs(now - lastMeasureTime);
        if (elapsedMs >= 1000.0) {
            measuredRealFPS = (double)presentedFramesCount * 1000.0 / elapsedMs;
            presentedFramesCount = 0;
            lastMeasureTime = now;
        }
    }
    return orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
}

// 4. Tối ưu VRAM & giữ Triple Buffering (maximumDrawableCount = 3 để tránh tụt 30 FPS)
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

// 5. Chặn điều tiết năng lượng & cảnh báo nhiệt
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

static void dumpComparisonLog(void) {
    NSMutableArray *linkStates = [NSMutableArray array];
    for (CADisplayLink *link in gameDisplayLinks) {
        double hz = (link.duration > 0) ? (1.0 / link.duration) : 0.0;
        [linkStates addObject:[NSString stringWithFormat:@"[paused:%d, hz:%.1f]", link.isPaused, hz]];
    }

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"=== BÁO CÁO NHỊP RENDER (KHÔI PHỤC TỪ 30 FPS) ===\n"];
    [msg appendFormat:@"- Nhịp gọi CCDirectorCaller::doCaller: %.1f lần/giây\n", measuredDirectorFPS];
    [msg appendFormat:@"- FPS xuất hình GPU (presentRenderbuffer): %.1f FPS\n", measuredRealFPS];
    [msg appendFormat:@"- Trạng thái các DisplayLink: %@\n", [linkStates componentsJoinedByString:@", "]];
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
        writeDebugLog(@"Khởi động FPSBooster (Đã gỡ invalidate DisplayLink)...");

        Class bundleClass = [NSBundle class];
        Method mObjForKey = class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:));
        if (mObjForKey) orig_objectForInfoDictionaryKey = method_setImplementation(mObjForKey, (IMP)hooked_objectForInfoDictionaryKey);

        Method mInfoDict = class_getInstanceMethod(bundleClass, @selector(infoDictionary));
        if (mInfoDict) orig_infoDictionary = method_setImplementation(mInfoDict, (IMP)hooked_infoDictionary);

        Method mMaxFps = class_getInstanceMethod([UIScreen class], @selector(maximumFramesPerSecond));
        if (mMaxFps) orig_maxFramesPerSecond = method_setImplementation(mMaxFps, (IMP)hooked_maxFramesPerSecond);

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
                if (mAnimInt) {
                    orig_setAnimationInterval = method_setImplementation(mAnimInt, (IMP)hooked_setAnimationInterval);
                }
                Method mDoCaller = class_getInstanceMethod(directorCallerClass, NSSelectorFromString(@"doCaller:"));
                if (mDoCaller) {
                    orig_doCaller = method_setImplementation(mDoCaller, (IMP)hooked_doCaller);
                }
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isBootComplete = YES;
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            for (CADisplayLink *link in gameDisplayLinks) {
                lockLinkTo120(link);
            }

            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                dumpComparisonLog();
            }];
        });
    }
}
