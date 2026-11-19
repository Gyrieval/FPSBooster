#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
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
static IMP orig_setDrawableProperties = NULL;
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_presentRenderbuffer = NULL;
static IMP orig_doCaller = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static NSString *logFilePath = nil;
static BOOL isBootComplete = NO;

// Biến đo đạc chi tiết
static NSInteger directorTicks = 0;
static NSInteger presentTicks = 0;
static NSInteger metalAnchorTicks = 0;
static double fpsDirector = 0.0;
static double fpsPresent = 0.0;
static double fpsMetalAnchor = 0.0;
static uint64_t lastSampleTime = 0;

static double lastAnimIntervalRequested = -1.0;
static BOOL anchorAttachedSuccess = NO;
static NSString *anchorAttachDetail = @"Chưa gắn";
static NSMutableArray *createdLinksLog = nil;

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

@interface FPSProMotionAnchor : NSObject
@property (nonatomic, strong) CAMetalLayer *anchorLayer;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) CADisplayLink *anchorLink;
@end

@implementation FPSProMotionAnchor
- (void)startOnWindow:(UIWindow *)window {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || !window) {
        anchorAttachedSuccess = NO;
        anchorAttachDetail = [NSString stringWithFormat:@"Lỗi: device=%p, window=%p", device, window];
        return;
    }

    self.commandQueue = [device newCommandQueue];
    self.anchorLayer = [CAMetalLayer layer];
    self.anchorLayer.device = device;
    self.anchorLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.anchorLayer.framebufferOnly = YES;
    self.anchorLayer.drawableSize = CGSizeMake(4, 4);
    self.anchorLayer.frame = CGRectMake(0, 0, 4, 4);
    self.anchorLayer.opacity = 0.02f;
    self.anchorLayer.presentsWithTransaction = NO;

    [window.layer addSublayer:self.anchorLayer];

    self.anchorLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickMetalAnchor:)];
    if (@available(iOS 15.0, *)) {
        self.anchorLink.preferredFrameRateRange = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
    }
    self.anchorLink.preferredFramesPerSecond = 120;
    [self.anchorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    anchorAttachedSuccess = YES;
    anchorAttachDetail = [NSString stringWithFormat:@"OK trên %@ (frame: %@)", NSStringFromClass([window class]), NSStringFromCGRect(window.frame)];
}

- (void)tickMetalAnchor:(CADisplayLink *)sender {
    metalAnchorTicks++;
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [self.anchorLayer nextDrawable];
        if (drawable && self.commandQueue) {
            id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
            [cmdBuf presentDrawable:drawable];
            [cmdBuf commit];
        }
    }
}
@end

static FPSProMotionAnchor *globalAnchor = nil;

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

// 2. Khóa nhịp CADisplayLink (Bắt cả CADisplayLink và UIScreen)
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

static void recordCreatedLink(CADisplayLink *link, NSString *source, id target, SEL sel) {
    if (!link) return;
    if (!gameDisplayLinks) gameDisplayLinks = [NSHashTable weakObjectsHashTable];
    if (!createdLinksLog) createdLinksLog = [NSMutableArray array];
    [gameDisplayLinks addObject:link];
    [createdLinksLog addObject:[NSString stringWithFormat:@"[%@] %@::%@", source, NSStringFromClass([target class]), NSStringFromSelector(sel)]];
    lockLinkTo120(link);
}

static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    recordCreatedLink(link, @"CADisplayLink", target, sel);
    return link;
}

static CADisplayLink *hooked_screenDisplayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_screenDisplayLinkWithTarget)(self, _cmd, target, sel);
    recordCreatedLink(link, @"UIScreen", target, sel);
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
    lastAnimIntervalRequested = interval;
    if (orig_setAnimationInterval) {
        ((void (*)(id, SEL, double))orig_setAnimationInterval)(self, _cmd, (1.0 / 120.0));
    }
    for (CADisplayLink *link in gameDisplayLinks) {
        lockLinkTo120(link);
    }
}

// 3. Đo tần số từng tầng: Metal Anchor vs CCDirectorCaller vs OpenGL Present
static void updateFPSCountersIfNeeded(void) {
    uint64_t now = mach_absolute_time();
    if (lastSampleTime == 0) {
        lastSampleTime = now;
        return;
    }
    double elapsedMs = machTicksToMs(now - lastSampleTime);
    if (elapsedMs >= 1000.0) {
        fpsDirector = (double)directorTicks * 1000.0 / elapsedMs;
        fpsPresent = (double)presentTicks * 1000.0 / elapsedMs;
        fpsMetalAnchor = (double)metalAnchorTicks * 1000.0 / elapsedMs;
        directorTicks = 0;
        presentTicks = 0;
        metalAnchorTicks = 0;
        lastSampleTime = now;
    }
}

static void hooked_doCaller(id self, SEL _cmd, id sender) {
    directorTicks++;
    updateFPSCountersIfNeeded();
    if (orig_doCaller) {
        ((void (*)(id, SEL, id))orig_doCaller)(self, _cmd, sender);
    }
}

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    presentTicks++;
    updateFPSCountersIfNeeded();
    return orig_presentRenderbuffer ? ((BOOL (*)(id, SEL, NSUInteger))orig_presentRenderbuffer)(self, _cmd, target) : YES;
}

// 4. VRAM & Low Power / Thermal
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

static void dumpDeepDiagnosticLog(void) {
    id plistVal = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"];
    NSInteger screenMax = [UIScreen mainScreen].maximumFramesPerSecond;

    NSMutableArray *linksDetail = [NSMutableArray array];
    for (CADisplayLink *link in gameDisplayLinks) {
        double durHz = (link.duration > 0) ? (1.0 / link.duration) : 0.0;
        NSInteger prefFps = link.preferredFramesPerSecond;
        float minR = 0, maxR = 0, prefR = 0;
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange r = link.preferredFrameRateRange;
            minR = r.minimum; maxR = r.maximum; prefR = r.preferred;
        }
        [linksDetail addObject:[NSString stringWithFormat:@"{paused:%d, durHz:%.1f, prefFPS:%ld, range:[%.0f-%.0f-%.0f]}",
                                link.isPaused, durHz, (long)prefFps, minR, prefR, maxR]];
    }

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"=== CHẨN ĐOÁN SÂU 70-80 FPS (METAL ANCHOR + LIVECONTAINER) ===\n"];
    [msg appendFormat:@"- Nhịp Metal Anchor: %.1f Hz | CCDirectorCaller: %.1f Hz | GPU Present: %.1f FPS\n", fpsMetalAnchor, fpsDirector, fpsPresent];
    [msg appendFormat:@"- Trạng thái Metal Anchor: %@\n", anchorAttachDetail];
    [msg appendFormat:@"- Bundle Key: %@ | UIScreen MaxFPS: %ld | Game yêu cầu Interval: %.5f\n", plistVal, (long)screenMax, lastAnimIntervalRequested];
    [msg appendFormat:@"- Nguồn tạo DisplayLink: %@\n", [createdLinksLog componentsJoinedByString:@", "]];
    [msg appendFormat:@"- Thuộc tính thực tế của DisplayLink: %@\n", [linksDetail componentsJoinedByString:@" | "]];
    [msg appendString:@"============================================================="];
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
        writeDebugLog(@"Khởi động FPSBooster Deep Diagnostic...");

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

            UIWindow *keyWindow = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (w.isKeyWindow) {
                            keyWindow = w;
                            break;
                        }
                    }
                }
            }
            if (!keyWindow) {
                keyWindow = [UIApplication sharedApplication].windows.firstObject;
            }
            globalAnchor = [[FPSProMotionAnchor alloc] init];
            [globalAnchor startOnWindow:keyWindow];

            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                dumpDeepDiagnosticLog();
            }];
        });
    }
}
