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
static IMP orig_setDrawableProperties = NULL;
static IMP orig_metalLayoutSublayers = NULL;
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

// 1. Khóa cứng 120 FPS cho mọi CADisplayLink của game
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

static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    lockLinkTo120((CADisplayLink *)self);
}

static void hooked_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    lockLinkTo120((CADisplayLink *)self);
}

// 2. Tối ưu bộ đệm VRAM cho OpenGL ES & Metal trên iOS 27.0.1
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

// 4. Tạo CoreAnimation 120Hz ở cấp độ WindowServer để ngăn LTPO tự hạ xuống 80Hz/60Hz
static void startCompositor120HzAnchor(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *w in windowScene.windows) {
                if (w.isKeyWindow) {
                    keyWindow = w;
                    break;
                }
            }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) return;

    // Tránh tạo trùng nếu đã có
    if ([keyWindow viewWithTag:99120]) return;

    UIView *anchorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    anchorView.tag = 99120;
    anchorView.userInteractionEnabled = NO;
    anchorView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.01];
    [keyWindow addSubview:anchorView];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @(0.01);
    pulse.toValue = @(0.02);
    pulse.duration = 1.0;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.removedOnCompletion = NO;
    if (@available(iOS 15.0, *)) {
        pulse.preferredFrameRateRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    }
    [anchorView.layer addAnimation:pulse forKey:@"ProMotion120Lock"];
}

%ctor {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        Class displayLinkClass = [CADisplayLink class];
        Method mCreate = class_getClassMethod(displayLinkClass, @selector(displayLinkWithTarget:selector:));
        if (mCreate) orig_displayLinkWithTarget = method_setImplementation(mCreate, (IMP)hooked_displayLinkWithTarget);

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

        // Kích hoạt neo CoreAnimation 120Hz trên cửa sổ chính và duy trì khóa FPS
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            startCompositor120HzAnchor();

            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                startCompositor120HzAnchor();
                for (CADisplayLink *link in gameDisplayLinks) {
                    lockLinkTo120(link);
                }
            }];
        });
    }
}
