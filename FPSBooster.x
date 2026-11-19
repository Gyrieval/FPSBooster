#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

// Đặt mức FPS giới hạn mong muốn: 120 (cho iPhone Pro 120Hz) hoặc 60 (khóa 60Hz ổn định)
#define TARGET_FPS 120

static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;

// 1. Hook CADisplayLink -setPreferredFramesPerSecond: (iOS 10+)
static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(self, _cmd, TARGET_FPS);
    }
}

// 2. Hook CADisplayLink -setPreferredFrameRateRange: (iOS 15+ ProMotion)
static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    CAFrameRateRange lockedRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    if (orig_setPreferredFrameRateRange) {
        ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(self, _cmd, lockedRange);
    }
}

// 3. Ngăn game tự hạ chất lượng / hạ FPS khi hệ thống báo Low Power Mode
static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) {
    return NO;
}

// 4. Nâng mức ưu tiên luồng xử lý hiện tại lên mức tương tác người dùng tối đa (User Interactive)
static void boostThreadPriority(void) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    [[NSThread currentThread] setThreadPriority:1.0];
}

%ctor {
    @autoreleasepool {
        boostThreadPriority();

        // Hook CADisplayLink để khóa cứng giới hạn FPS
        Class displayLinkClass = [CADisplayLink class];
        
        Method m1 = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (m1) {
            orig_setPreferredFramesPerSecond = method_setImplementation(m1, (IMP)hooked_setPreferredFramesPerSecond);
        }

        if (@available(iOS 15.0, *)) {
            Method m2 = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (m2) {
                orig_setPreferredFrameRateRange = method_setImplementation(m2, (IMP)hooked_setPreferredFrameRateRange);
            }
        }

        // Hook NSProcessInfo để chặn cơ chế bóp FPS khi pin yếu
        Class processInfoClass = [NSProcessInfo class];
        Method m3 = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (m3) {
            orig_isLowPowerModeEnabled = method_setImplementation(m3, (IMP)hooked_isLowPowerModeEnabled);
        }

        // Sau khi UIApplication khởi tạo xong, giữ màn hình luôn sáng và ép ưu tiên luồng chính
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            boostThreadPriority();
            [UIApplication sharedApplication].idleTimerDisabled = YES;
        });
    }
}
