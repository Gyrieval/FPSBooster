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
static IMP orig_setDrawableProperties = NULL;
static IMP orig_metalLayoutSublayers = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;

static NSHashTable *gameDisplayLinks = nil;
static NSDictionary *cachedPatchedInfoDict = nil;
static NSString *logFilePath = nil;

// Thống kê cho Log chẩn đoán
static NSInteger stat_gameRequestedFPS = 0;
static NSInteger stat_displayLinkCount = 0;
static BOOL stat_eaglDetected = NO;
static BOOL stat_metalDetected = NO;
static NSString *stat_layerClassName = @"Chưa khởi tạo";

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

// 1. Giả lập Info.plist trong RAM (Cache 1 lần duy nhất để không làm trễ CPU gây tụt 70 FPS)
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

// 2. Báo cáo UIScreen hỗ trợ 120Hz (chỉ để bypass chốt 60 FPS của Arcaea)
static NSInteger hooked_maxFramesPerSecond(id self, SEL _cmd) {
    return TARGET_FPS;
}

// 3. Khóa nhịp CADisplayLink trên NSRunLoopCommonModes
static inline void lockLinkToTarget(CADisplayLink *link) {
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

static CADisplayLink *hooked_displayLinkWithTarget(id self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = ((CADisplayLink *(*)(id, SEL, id, SEL))orig_displayLinkWithTarget)(self, _cmd, target, sel);
    if (link) {
        stat_displayLinkCount++;
        if (!gameDisplayLinks) {
            gameDisplayLinks = [NSHashTable weakObjectsHashTable];
        }
        [gameDisplayLinks addObject:link];
        lockLinkToTarget(link);
        writeDebugLog([NSString stringWithFormat:@"Tạo CADisplayLink #%ld (target: %@) -> Ép khóa %d FPS", (long)stat_displayLinkCount, NSStringFromClass([target class]), TARGET_FPS]);
    }
    return link;
}

static void hooked_addToRunLoop(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    if (orig_addToRunLoop) {
        ((void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))orig_addToRunLoop)(self, _cmd, runloop, NSRunLoopCommonModes);
    }
    lockLinkToTarget((CADisplayLink *)self);
}

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (fps != stat_gameRequestedFPS) {
        stat_gameRequestedFPS = fps;
        writeDebugLog([NSString stringWithFormat:@"Game yêu cầu setPreferredFramesPerSecond: %ld -> Chặn và ép về %d FPS", (long)fps, TARGET_FPS]);
    }
    lockLinkToTarget((CADisplayLink *)self);
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    if ((NSInteger)range.preferred != stat_gameRequestedFPS) {
        stat_gameRequestedFPS = (NSInteger)range.preferred;
        writeDebugLog([NSString stringWithFormat:@"Game yêu cầu Range(min:%.0f, max:%.0f, pref:%.0f) -> Ép về %d FPS", range.minimum, range.maximum, range.preferred, TARGET_FPS]);
    }
    lockLinkToTarget((CADisplayLink *)self);
}

static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    writeDebugLog([NSString stringWithFormat:@"Game gọi setFrameInterval: %ld -> Chặn và ép về %d FPS", (long)interval, TARGET_FPS]);
    lockLinkToTarget((CADisplayLink *)self);
}

// 4. Tối ưu VRAM (Gỡ bỏ setValue preferredFramesPerSecond trên CAMetalLayer vì gây lệch pha 70 FPS)
static void hooked_setDrawableProperties(id self, SEL _cmd, NSDictionary *props) {
    stat_eaglDetected = YES;
    stat_layerClassName = NSStringFromClass([self class]);
    NSMutableDictionary *optProps = props ? [NSMutableDictionary dictionaryWithDictionary:props] : [NSMutableDictionary dictionary];
    optProps[@"EAGLDrawablePropertyRetainedBacking"] = @NO;
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(self, _cmd, optProps);
    }
    writeDebugLog([NSString stringWithFormat:@"Khởi tạo OpenGL ES Layer (%@) -> RetainedBacking = NO", stat_layerClassName]);
}

static void hooked_metalLayoutSublayers(id self, SEL _cmd) {
    if (orig_metalLayoutSublayers) {
        ((void (*)(id, SEL))orig_metalLayoutSublayers)(self, _cmd);
    }
    if ([self isKindOfClass:[CAMetalLayer class]]) {
        stat_metalDetected = YES;
        CAMetalLayer *metalLayer = (CAMetalLayer *)self;
        if ([metalLayer respondsToSelector:@selector(setPresentsWithTransaction:)]) {
            metalLayer.presentsWithTransaction = NO;
        }
        if ([metalLayer respondsToSelector:@selector(setFramebufferOnly:)]) {
            metalLayer.framebufferOnly = YES;
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

// 6. Ghi báo cáo chẩn đoán chi tiết phần cứng & nút thắt cổ chai
static void dumpDiagnosticsReport(void) {
    UIScreen *mainScreen = [UIScreen mainScreen];
    NSInteger realHardwareMax = orig_maxFramesPerSecond ? ((NSInteger (*)(id, SEL))orig_maxFramesPerSecond)(mainScreen, @selector(maximumFramesPerSecond)) : 0;
    BOOL isCaptured = mainScreen.isCaptured;
    BOOL realLowPower = orig_isLowPowerModeEnabled ? ((BOOL (*)(id, SEL))orig_isLowPowerModeEnabled)([NSProcessInfo processInfo], @selector(isLowPowerModeEnabled)) : NO;
    NSProcessInfoThermalState realThermal = orig_thermalState ? ((NSProcessInfoThermalState (*)(id, SEL))orig_thermalState)([NSProcessInfo processInfo], @selector(thermalState)) : 0;

    id plistKeyVal = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"];

    // Kiểm tra nhịp VSync thực tế của CADisplayLink đầu tiên
    double actualHardwareHz = 0.0;
    CADisplayLink *firstLink = [[gameDisplayLinks allObjects] firstObject];
    if (firstLink && firstLink.duration > 0) {
        actualHardwareHz = 1.0 / firstLink.duration;
    }

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"=== BÁO CÁO CHẨN ĐOÁN FPSBOOSTER ===\n"];
    [report appendFormat:@"- iOS Version: %@\n", [[UIDevice currentDevice] systemVersion]];
    [report appendFormat:@"- UIScreen Max FPS (Gốc phần cứng): %ld Hz | (Sau hook): %ld Hz\n", (long)realHardwareMax, (long)mainScreen.maximumFramesPerSecond];
    [report appendFormat:@"- Nhịp VSync thực tế WindowServer cấp cho CADisplayLink: %.1f Hz (duration: %.5fs)\n", actualHardwareHz, firstLink ? firstLink.duration : 0.0];
    [report appendFormat:@"- Trạng thái Ghi màn hình (isCaptured): %@\n", isCaptured ? @"BẬT" : @"TẮT"];
    [report appendFormat:@"- Info.plist CADisableMinimumFrameDurationOnPhone trong RAM: %@\n", plistKeyVal];
    [report appendFormat:@"- API Đồ họa game đang dùng: %@ (OpenGL ES: %@, Metal Layer: %@)\n", stat_layerClassName, stat_eaglDetected ? @"CÓ" : @"KHÔNG", stat_metalDetected ? @"CÓ" : @"KHÔNG"];
    [report appendFormat:@"- Số lượng CADisplayLink active: %lu | FPS cuối cùng game tự yêu cầu: %ld\n", (unsigned long)gameDisplayLinks.count, (long)stat_gameRequestedFPS];
    [report appendFormat:@"- Low Power Mode gốc: %@ | ThermalState gốc: %ld\n", realLowPower ? @"BẬT" : @"TẮT", (long)realThermal];

    if (actualHardwareHz > 0 && actualHardwareHz < 100.0 && !isCaptured) {
        [report appendString:@"=> CHẨN ĐOÁN NGUYÊN NHÂN: WindowServer của iOS đang khóa trần VSync ở 80Hz vì game dùng OpenGL ES (CAEAGLLayer) và đang TẮT Ghi màn hình.\n"];
    }
    [report appendString:@"====================================="];
    writeDebugLog(report);
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        // Xóa log cũ mỗi lần khởi động game để dễ đọc
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            logFilePath = [paths[0] stringByAppendingPathComponent:@"fps_debug.log"];
            [[NSFileManager defaultManager] removeItemAtPath:logFilePath error:nil];
        }
        writeDebugLog(@"FPSBooster đã tiêm thành công vào tiến trình!");

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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            dumpDiagnosticsReport();

            [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                for (CADisplayLink *link in gameDisplayLinks) {
                    lockLinkToTarget(link);
                }
                dumpDiagnosticsReport();
            }];
        });
    }
}
