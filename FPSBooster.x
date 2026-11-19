#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

// Đặt mức FPS giới hạn mong muốn:
// - 120: Mở khóa và giữ 120 FPS (cho iPhone Pro / Pro Max)
// - 60: Khóa cứng 60 FPS ổn định (chống nóng máy và tụt xung trên mọi dòng máy)
#define TARGET_FPS 120

static IMP orig_infoDictionary = NULL;
static IMP orig_objectForInfoDictionaryKey = NULL;
static IMP orig_setPreferredFramesPerSecond = NULL;
static IMP orig_setPreferredFrameRateRange = NULL;
static IMP orig_isLowPowerModeEnabled = NULL;

// 1. Tiêm trực tiếp CADisableMinimumFrameDurationOnPhone = YES vào RAM (không cần sửa file Info.plist)
static NSDictionary *hooked_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        if (![dict[@"CADisableMinimumFrameDurationOnPhone"] boolValue]) {
            NSMutableDictionary *mutableDict = [dict mutableCopy];
            mutableDict[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
            return [mutableDict copy];
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

// 2. Khóa cứng tốc độ khung hình trên CADisplayLink (iOS 10+)
static void hooked_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (orig_setPreferredFramesPerSecond) {
        ((void (*)(id, SEL, NSInteger))orig_setPreferredFramesPerSecond)(self, _cmd, TARGET_FPS);
    }
}

// 3. Khóa cứng dải tần số quét trên ProMotion (iOS 15+)
static void hooked_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) API_AVAILABLE(ios(15.0)) {
    CAFrameRateRange lockedRange = CAFrameRateRangeMake(TARGET_FPS, TARGET_FPS, TARGET_FPS);
    if (orig_setPreferredFrameRateRange) {
        ((void (*)(id, SEL, CAFrameRateRange))orig_setPreferredFrameRateRange)(self, _cmd, lockedRange);
    }
}

// 4. Ngăn game tự hạ FPS khi hệ thống báo Low Power Mode
static BOOL hooked_isLowPowerModeEnabled(id self, SEL _cmd) {
    return NO;
}

// 5. Ép luồng xử lý lên mức ưu tiên tương tác cao nhất (User Interactive)
static void boostThreadPriority(void) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    [[NSThread currentThread] setThreadPriority:1.0];
}

%ctor {
    @autoreleasepool {
        boostThreadPriority();

        // Hook NSBundle để giả lập khóa ProMotion 120Hz trong bộ nhớ
        Class bundleClass = [NSBundle class];
        Method mInfoDict = class_getInstanceMethod(bundleClass, @selector(infoDictionary));
        if (mInfoDict) {
            orig_infoDictionary = method_setImplementation(mInfoDict, (IMP)hooked_infoDictionary);
        }
        Method mObjForKey = class_getInstanceMethod(bundleClass, @selector(objectForInfoDictionaryKey:));
        if (mObjForKey) {
            orig_objectForInfoDictionaryKey = method_setImplementation(mObjForKey, (IMP)hooked_objectForInfoDictionaryKey);
        }

        // Hook CADisplayLink để khóa giới hạn FPS
        Class displayLinkClass = [CADisplayLink class];
        Method mFps = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFramesPerSecond:));
        if (mFps) {
            orig_setPreferredFramesPerSecond = method_setImplementation(mFps, (IMP)hooked_setPreferredFramesPerSecond);
        }

        if (@available(iOS 15.0, *)) {
            Method mRange = class_getInstanceMethod(displayLinkClass, @selector(setPreferredFrameRateRange:));
            if (mRange) {
                orig_setPreferredFrameRateRange = method_setImplementation(mRange, (IMP)hooked_setPreferredFrameRateRange);
            }
        }

        // Hook NSProcessInfo để chặn bóp hiệu năng khi pin yếu
        Class processInfoClass = [NSProcessInfo class];
        Method mLowPower = class_getInstanceMethod(processInfoClass, @selector(isLowPowerModeEnabled));
        if (mLowPower) {
            orig_isLowPowerModeEnabled = method_setImplementation(mLowPower, (IMP)hooked_isLowPowerModeEnabled);
        }

        // Giữ màn hình luôn sáng và duy trì mức ưu tiên luồng chính
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            boostThreadPriority();
            [UIApplication sharedApplication].idleTimerDisabled = YES;
        });
    }
}
