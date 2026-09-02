// StepFaker —— 干净的注入式 tweak（与 HealthBoost App-only deb 分开打包）
//
// 设计要点（来自验证结论）：
//   1) 微信运动 / 支付宝运动 显示的步数来源不同：
//      - 微信：走 CoreMotion 的 CMPedometerData.numberOfSteps（实测命中）
//      - 支付宝：走 HealthKit 的聚合查询（HKStatistics 的 sumQuantity，或
//        HKSampleQuery 的样本数组），不经过 CMPedometerData 的 getter
//      所以单 hook CMPedometerData 只对微信有效，必须再覆盖 HealthKit 两条路径。
//   2) 只注入 com.tencent.xin（微信）与 com.alipay.iphoneclient（支付宝），
//      绝不碰 SpringBoard / 本 App / 其他进程 —— 这是与旧版「无 Filter 注入所有进程」
//      导致 App 闪退 + ElleKit corrupted 的根本区别。
//   3) 目标步数由 HealthBoost App 写入：
//        - 通道A：写进微信/支付宝容器 Documents/hb_steps.txt（App 带 no-sandbox 可扫到容器）
//        - 通道B：写进 CFPreferences 系统域 com.apple.mobile.healthboost / steps
//      tweak 跑在对应进程内，读这两个通道之一即可拿到假步数；为 0 时原样放行。
//
// 编译（CI 内 macos-latest）：
//   xcrun --sdk iphoneos clang -dynamiclib -fobjc-arc \
//     -framework Foundation -framework CoreFoundation -framework CoreMotion -framework HealthKit \
//     -arch arm64 -arch arm64e -mios-version-min=13.0 -isysroot $SDK \
//     -o StepFaker.dylib tweak/StepFaker.m
// 签名：ldid -M -S StepFaker.dylib

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <HealthKit/HealthKit.h>

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
                // 非持有桥接：仅读取，不转移所有权；下方统一 CFRelease 平衡 Copy 的 +1
                NSString *s = (__bridge NSString *)val;
                v = [s integerValue];
            }
            CFRelease(val);
            if (v > 0) return v;
        }
        return 0;
    }
}

// ---------------------------------------------------------------------------
// 路径一：CoreMotion 的 CMPedometerData.numberOfSteps（微信命中）
// ---------------------------------------------------------------------------
static NSNumber *(*orig_numberOfSteps)(id, SEL) = NULL;
static NSNumber *new_numberOfSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) return @(fake);
    return orig_numberOfSteps(self, _cmd);
}

// ---------------------------------------------------------------------------
// 路径二：HealthKit 的 HKStatistics 聚合查询（支付宝常见路径之一）
//   HKStatisticsQuery 的 resultsHandler 会拿到 HKStatistics，支付宝读
//   [statistics sumQuantity] / [statistics averageQuantity] 再 doubleValue。
// ---------------------------------------------------------------------------
static id (*orig_sumQ)(id, SEL) = NULL;
static id new_sumQ(id self, SEL _cmd) {
    id type = [self quantityType];
    if (type && [[type identifier] isEqualToString:@"HKQuantityTypeIdentifierStepCount"]) {
        NSInteger fake = HBReadFakeSteps();
        if (fake > 0) {
            HKUnit *unit = [HKUnit countUnit];
            return [HKQuantity quantityWithUnit:unit doubleValue:(double)fake];
        }
    }
    return orig_sumQ(self, _cmd);
}

static id (*orig_avgQ)(id, SEL) = NULL;
static id new_avgQ(id self, SEL _cmd) {
    id type = [self quantityType];
    if (type && [[type identifier] isEqualToString:@"HKQuantityTypeIdentifierStepCount"]) {
        NSInteger fake = HBReadFakeSteps();
        if (fake > 0) {
            HKUnit *unit = [HKUnit countUnit];
            return [HKQuantity quantityWithUnit:unit doubleValue:(double)fake];
        }
    }
    return orig_avgQ(self, _cmd);
}

// ---------------------------------------------------------------------------
// 路径三：HealthKit 的 HKSampleQuery 逐样本查询（支付宝常见路径之二）
//   把 results 替换成单个 HKQuantitySample（quantity=假步数），支付宝 sum 即得假值。
// ---------------------------------------------------------------------------
static id (*orig_SQ_init)(id, SEL, id, id, unsigned long, id, id) = NULL;
static id new_SQ_init(id self, SEL _cmd,
                      id type, id pred, unsigned long limit, id sorts, id handler) {
    if (type && [[type identifier] isEqualToString:@"HKQuantityTypeIdentifierStepCount"]) {
        NSInteger fake = HBReadFakeSteps();
        if (fake > 0 && handler) {
            id origHandler = handler;
            id newHandler = ^(id q, id results, id error) {
                @autoreleasepool {
                    HKUnit *unit = [HKUnit countUnit];
                    HKQuantity *qty = [HKQuantity quantityWithUnit:unit doubleValue:(double)fake];
                    HKQuantitySample *sample = [HKQuantitySample
                        quantitySampleWithType:type
                                      quantity:qty
                                     startDate:[NSDate dateWithTimeIntervalSince1970:0]
                                       endDate:[NSDate date]];
                    NSArray *newResults = @[ sample ];
                    void (^h)(id, id, id) = origHandler;
                    h(q, newResults, error);
                }
            };
            return orig_SQ_init(self, _cmd, type, pred, limit, sorts, newHandler);
        }
    }
    return orig_SQ_init(self, _cmd, type, pred, limit, sorts, handler);
}

// ---------------------------------------------------------------------------
// 运行时 hook（带重试，因为 HealthKit 框架可能尚未加载）
// ---------------------------------------------------------------------------
static void StepFakerTryHookHealthKit(void) {
    static BOOL hkDone = NO;
    if (hkDone) return;

    Class statCls = objc_getClass("HKStatistics");
    Class sqCls   = objc_getClass("HKSampleQuery");
    if (!statCls && !sqCls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ StepFakerTryHookHealthKit(); });
        return;
    }

    if (statCls) {
        if (orig_sumQ == NULL) {
            Method m = class_getInstanceMethod(statCls, @selector(sumQuantity));
            if (m) { orig_sumQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_sumQ); }
        }
        if (orig_avgQ == NULL) {
            Method m = class_getInstanceMethod(statCls, @selector(averageQuantity));
            if (m) { orig_avgQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_avgQ); }
        }
    }

    if (sqCls && orig_SQ_init == NULL) {
        Method m = class_getInstanceMethod(sqCls,
            @selector(initWithSampleType:predicate:limit:sortDescriptors:resultsHandler:));
        if (m) { orig_SQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_SQ_init); }
    }

    hkDone = YES;
}

static void StepFakerTryHookPedometer(void) {
    static BOOL pedDone = NO;
    if (pedDone) return;
    Class cls = objc_getClass("CMPedometerData");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ StepFakerTryHookPedometer(); });
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
    if (!m) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ StepFakerTryHookPedometer(); });
        return;
    }
    if (orig_numberOfSteps == NULL) {
        orig_numberOfSteps = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)new_numberOfSteps);
    }
    pedDone = YES;
}

__attribute__((constructor)) static void StepFakerInit(void) {
    StepFakerTryHookPedometer();
    StepFakerTryHookHealthKit();
}
