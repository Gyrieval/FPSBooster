#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGLDrawable.h>
#import <objc/runtime.h>
#import <pthread.h>

// Đặt 120 (cho iPhone Pro 120Hz) hoặc 60 (khóa phẳng 60 FPS)
#define TARGET_FPS 120

static IMP orig_infoDictionary = NULL;
static IMP orig_objectForInfoDictionaryKey = NULL;
static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_setFrameInterval = NULL;
static IMP orig_setDrawableProperties = NULL;
static IMP orig_eaglLayoutSublayers = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;
static IMP orig_thermalState = NULL;
static IMP orig_isCaptured = NULL;

// Đối tượng giữ nhịp VSync liên tục (hàm rỗng 0% CPU, ngăn ProMotion tự hạ Hz giữa các lần chạm)
@interface VSyncKeepAlive : NSObject
- (void)keepVSync:(CADisplayLink *)sender;
@end

@implementation VSyncKeepAlive
- (void)keepVSync:(CADisplayLink *)sender {
    // Hàm rỗng: chỉ giữ tín hiệu phần cứng ProMotion ở mức TARGET_FPS mà không tốn chu kỳ CPU
}
@end

static VSyncKeepAlive *keepAliveTarget = nil;
static CADisplayLink *keepAliveLink = nil;

// 1. Tiêm khóa ProMotion 120Hz an toàn vào mainBundle
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

// 2. Khóa cứng FPS mỗi khi game khởi tạo hoặc đổi nhịp CADisplayLink
static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(self, _cmd, TARGET_FPS);
    }
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    CAFrameRateRange locked = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    if (orig_setPreferredFrameRateRange) {
        ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(self, _cmd, locked);
    }
}

static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    if (orig_setFrameInterval) {
        ((void (*)(id, SEL, NSInteger))orig_setFrameInterval)(self, _cmd, 1);
    }
}

// 3. Áp dụng cơ chế tối ưu bộ đệm GPU giống chế độ quay/truyền phát cho mọi CAEAGLLayer
static void applyOptimalLayerProperties(CAEAGLLayer *layer) {
    if (!layer) return;
    layer.presentsWithTransaction = NO;
    NSDictionary *optProps = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
    };
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(layer, @selector(setDrawableProperties:), optProps);
    }
}

static void hooked_setDrawableProperties(id self, SEL _cmd, NSDictionary *props) {
    NSMutableDictionary *optProps = props ? [NSMutableDictionary dictionaryWithDictionary:props] : [NSMutableDictionary dictionary];
    optProps[kEAGLDrawablePropertyRetainedBacking] = @NO;
    if (orig_setDrawableProperties) {
        ((void (*)(id, SEL, NSDictionary *))orig_setDrawableProperties)(self, _cmd, optProps);
    }
}

static void hooked_eaglLayoutSublayers(id self, SEL _cmd) {
    if (orig_eaglLayoutSublayers) {
        ((void (*)(id, SEL))orig_eaglLayoutSublayers)(self, _cmd);
    }
    applyOptimalLayerProperties((CAEAGLLayer *)self);
}

// 4. Giả lập trạng thái compositor liên tục & chặn bóp xung nhiệt/tiết kiệm pin
static BOOL hooked_isCaptured(id self, SEL _cmd) {
    return YES;
}

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

        // Hook NSBundle
        Class bundleClass = [NSBundle class];
        Method mInfoDict = class_getInstanceMethod(bundleClass, @selector(infoDictionary));
        if (mInfoDict) orig_infoDictionary = method_setImplementation(mInfoDict, (IMP)hooked_infoDictionary);

        Method mObjForKey = class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:));
        if (mObjForKey) orig_objectForInfoDictionaryKey = method_setImplementation(mObjForKey, (IMP)hooked_objectForInfoDictionaryKey);

        // Hook CADisplayLink
        Class displayLinkClass = [CADisplayLink class];
        Method mFps = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (mFps) orig_setPreferredFramesPerSecond = method_setImplementation(mFps, (IMP)hooked_setPreferredFramesPerSecond);

        if (@available(iOS 15.0, *)) {
            Method mRange = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (mRange) orig_setPreferredFrameRateRange = method_setImplementation(mRange, (IMP)hooked_setPreferredFrameRateRange);
        }

        Method mInterval = class_getInstanceMethod(displayLinkClass, @selector(setFrameInterval:));
        if (mInterval) orig_setFrameInterval = method_setImplementation(mInterval, (IMP)hooked_setFrameInterval);

        // Hook CAEAGLLayer (tự động tối ưu ngay cả khi layer màn chơi được tạo muộn)
        Class eaglLayerClass = [CAEAGLLayer class];
        if (eaglLayerClass) {
            Method mDrawProps = class_getInstanceMethod(eaglLayerClass, @selector(setDrawableProperties:));
            if (mDrawProps) orig_setDrawableProperties = method_setImplementation(mDrawProps, (IMP)hooked_setDrawableProperties);

            Method mLayout = class_getInstanceMethod(eaglLayerClass, @selector(layoutSublayers));
            if (mLayout) orig_eaglLayoutSublayers = method_setImplementation(mLayout, (IMP)hooked_eaglLayoutSublayers);
        }

        // Hook UIScreen isCaptured để duy trì pipeline xuất hình liên tục như lúc quay/truyền phát
        Method mCaptured = class_getInstanceMethod([UIScreen class], @selector(isCaptured));
        if (mCaptured) orig_isCaptured = method_setImplementation(mCaptured, (IMP)hooked_isCaptured);

        // Hook NSProcessInfo
        Class processInfoClass = [NSProcessInfo class];
        Method mLowPower = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (mLowPower) orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);

        Method mThermal = class_getInstanceMethod(processInfoClass, @selector(thermalState));
        if (mThermal) orig_thermalState = method_setImplementation(mThermal, (IMP)hooked_thermalState);

        // Kích hoạt bộ giữ nhịp VSync rỗng (0% CPU) sau khi UIWindow sẵn sàng
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;

            keepAliveTarget = [[VSyncKeepAlive alloc] init];
            keepAliveLink = [CADisplayLink displayLinkWithTarget:keepAliveTarget selector:@selector(keepVSync:)];
            if (@available(iOS 15.0, *)) {
                keepAliveLink.preferredFrameRateRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
            }
            keepAliveLink.preferredFramesPerSecond = TARGET_FPS;
            [keepAliveLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
    }
}
