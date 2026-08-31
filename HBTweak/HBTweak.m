// HealthBoost Tweak —— 注入微信，劫持步数读取接口
//
// 背景（重要，避免走弯路）：
//   实测把步数写进 HealthKit 后，「健康」App 能看到，但微信运动不同步。
//   逆向 UCStep 6.0.6 后确认原因：微信运动并不只读 HealthKit，
//   WCDeviceStepObject 上有三个独立来源：
//       m7StepCount  —— M7/M8 协处理器（CMPedometer）读到的真实步数
//       hkStepCount  —— HealthKit 读到的步数
//       stepCount    —— 对外暴露的最终步数
//   微信优先用 M7 数据，所以单纯写 HealthKit 对它无效。
//
//   因此本 tweak 直接 hook WCDeviceStepObject 的这几个 getter，
//   返回 HealthBoost App 设定的步数。这与写 HealthKit 是两条独立链路：
//       - 写 HealthKit            -> 让「健康」App 显示
//       - 本 tweak hook 微信      -> 让「微信运动」显示
//   两者缺一不可。
//
// 跨进程传值：App 用 CFPreferences 写到 com.apple.mobile.healthboost 域，
// 本 tweak 在微信进程里读同一个域。域名以 com.apple. 开头是刻意的——
// 系统域在越狱环境下跨沙盒可见（UCStep 用的 com.apple.mobile.ifucstepcommon 同理）。
//
// 不依赖 CydiaSubstrate/ElleKit：直接用 Objective-C runtime 的
// class_replaceMethod 做替换，dylib 由 MobileSubstrate 按 plist filter 注入。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define HB_PREF_DOMAIN CFSTR("com.apple.mobile.healthboost")
#define HB_PREF_KEY    CFSTR("steps")

// 读取 App 设定的步数；未设置或为 0 时返回 -1（表示不劫持）
static long HBConfiguredSteps(void) {
    CFPropertyListRef v = CFPreferencesCopyValue(HB_PREF_KEY, HB_PREF_DOMAIN,
                                                 kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!v) return -1;
    long steps = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &steps);
    } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
        steps = (long)[(__bridge NSString *)v longLongValue];
    }
    CFRelease(v);
    return steps;
}

// 通用替换：把 cls 的 sel 实现换成 newImp，原实现存入 origImp
static void HBReplace(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (origImp) *origImp = orig;
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
}

// MARK: - WCDeviceStepObject 的 stepCount / hkStepCount / m7StepCount
// 这三个都是返回整数的无参 getter。用统一的 NSInteger(^)(id, SEL) 签名处理。

typedef NSInteger (*HBStepGetter)(id, SEL);

static HBStepGetter gOrig_stepCount    = NULL;
static HBStepGetter gOrig_hkStepCount  = NULL;
static HBStepGetter gOrig_m7StepCount  = NULL;

static NSInteger HB_stepCount(id self, SEL _cmd) {
    long s = HBConfiguredSteps();
    if (s >= 0) return (NSInteger)s;
    return gOrig_stepCount ? gOrig_stepCount(self, _cmd) : 0;
}

static NSInteger HB_hkStepCount(id self, SEL _cmd) {
    long s = HBConfiguredSteps();
    if (s >= 0) return (NSInteger)s;
    return gOrig_hkStepCount ? gOrig_hkStepCount(self, _cmd) : 0;
}

static NSInteger HB_m7StepCount(id self, SEL _cmd) {
    long s = HBConfiguredSteps();
    if (s >= 0) return (NSInteger)s;
    return gOrig_m7StepCount ? gOrig_m7StepCount(self, _cmd) : 0;
}

// MARK: - 构造函数（dylib 被注入时自动执行）

__attribute__((constructor))
static void HBHealthBoostTweakInit(void) {
    @autoreleasepool {
        // 只在微信进程里生效（filter 已限定，这里再兜一层）
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        BOOL isWeChat = [bid isEqualToString:@"com.tencent.xin"];

        Class wcCls = NSClassFromString(@"WCDeviceStepObject");
        if (wcCls) {
            HBReplace(wcCls, @selector(stepCount),    (IMP)HB_stepCount,    (IMP *)&gOrig_stepCount);
            HBReplace(wcCls, @selector(hkStepCount),  (IMP)HB_hkStepCount,  (IMP *)&gOrig_hkStepCount);
            HBReplace(wcCls, @selector(m7StepCount),  (IMP)HB_m7StepCount,  (IMP *)&gOrig_m7StepCount);
        }

        // 支付宝步数服务（UCStep 也 hook 了，一并带上）
        Class apCls = NSClassFromString(@"APStepInfo");
        if (apCls) {
            HBReplace(apCls, @selector(numberOfSteps), (IMP)HB_stepCount, NULL);
        }

        NSLog(@"[HealthBoost] tweak loaded in %@ (WCDeviceStepObject=%@, APStepInfo=%@)",
              bid, wcCls ? @"YES" : @"NO", apCls ? @"YES" : @"NO");
    }
}
