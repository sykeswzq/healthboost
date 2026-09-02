// StepFaker —— 干净的注入式 tweak（与 HealthBoost App-only deb 分开打包）
//
// 设计要点（来自验证结论）：
//   1) 微信运动 / 支付宝运动 显示的是 M7 协处理器经 CoreMotion 直读的步数，
//      根本不读 HealthKit 聚合总量。所以改「健康」App 步数对它们无效。
//   2) 因此这里只 hook CMPedometerData.numberOfSteps 这个 getter，
//      把返回值改成假步数。这是影响「运动步数」显示的最小、最安全切点。
//   3) 只注入 com.tencent.xin（微信）与 com.alipay.iphoneclient（支付宝），
//      绝不碰 SpringBoard / 本 App / 其他进程 —— 这是与旧版「无 Filter 注入所有进程」
//      导致 App 闪退 + ElleKit corrupted 的根本区别。
//   4) 目标步数由 HealthBoost App 写入：
//        - 通道A：写进微信/支付宝容器 Documents/hb_steps.txt（App 带 no-sandbox 可扫到容器）
//        - 通道B：写进 CFPreferences 系统域 com.apple.mobile.healthboost / steps
//      tweak 跑在对应进程内，读这两个通道之一即可拿到假步数；为 0 时原样放行。
//
// 编译（CI 内 macos-latest）：
//   xcrun --sdk iphoneos clang -dynamiclib -fobjc-arc \
//     -framework Foundation -framework CoreFoundation -framework CoreMotion \
//     -arch arm64 -arch arm64e -mios-version-min=13.0 -isysroot $SDK \
//     -o StepFaker.dylib tweak/StepFaker.m
// 签名：ldid -M -S StepFaker.dylib

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

// 读取目标步数（0 = 不篡改，原样放行）。
// 双通道冗余：先读自己容器 Documents/hb_steps.txt，再读 CFPreferences 系统域。
static NSInteger HBReadFakeSteps(void) {
    @autoreleasepool {
        // 通道A：本进程（微信/支付宝）自己容器里的文件，App 写进了这份
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = paths.firstObject;
        if (doc.length > 0) {
            NSString *p = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
            NSString *c = [NSString stringWithContentsOfFile:p
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
            if (c.length > 0) {
                NSString *line = [[c componentsSeparatedByString:@"\n"] firstObject];
                NSInteger v = [line integerValue];
                if (v > 0) return v;
            }
        }

        // 通道B：CFPreferences 系统域（App 用 kCFPreferencesAnyUser 写入，跨进程可读）
        CFPropertyListRef val = CFPreferencesCopyValue(
            CFSTR("steps"),
            CFSTR("com.apple.mobile.healthboost"),
            kCFPreferencesAnyUser,
            kCFPreferencesAnyHost);
        if (val) {
            NSInteger v = 0;
            if (CFGetTypeID(val) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)val, kCFNumberNSIntegerType, &v);
            } else if (CFGetTypeID(val) == CFStringGetTypeID()) {
                v = [(NSString *)val integerValue];
            }
            CFRelease(val);
            if (v > 0) return v;
        }
        return 0;
    }
}

// 原 getter 实现（保留以便放行时调用）
static NSNumber *(*orig_numberOfSteps)(id, SEL) = NULL;

// 替换后的 getter：返回假步数，或原值放行
static NSNumber *new_numberOfSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) return @(fake);
    return orig_numberOfSteps(self, _cmd);
}

// CMPedometerData 属于 CoreMotion，可能在 tweak 注入时尚未加载。
// 用重试机制等它可用后再 swizzle，避免 class 为 NULL 导致 hook 静默失败。
static void StepFakerTryHook(void) {
    Class cls = objc_getClass("CMPedometerData");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), StepFakerTryHook);
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
    if (!m) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), StepFakerTryHook);
        return;
    }
    if (orig_numberOfSteps == NULL) {
        orig_numberOfSteps = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)new_numberOfSteps);
    }
}

__attribute__((constructor)) static void StepFakerInit(void) {
    StepFakerTryHook();
}
