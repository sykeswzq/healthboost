// StepFaker —— 干净的注入式 tweak（安全探测版 1.0.136，补全 CoreMotion 入口探针）
//
// 设计：
//  - 仅注入 com.tencent.xin（微信）与 com.alipay.iphoneclient（支付宝）。
//  - 已知稳定可用的伪造逻辑（来自 1.0.131，微信已验证可用）：
//      * 微信：CMPedometerData.numberOfSteps
//      * 支付宝：HKStatistics sumQuantity/averageQuantity + HKSampleQuery
//  - 探测：只 hook 唯一的总入口 HKHealthStore executeQuery:（所有 HealthKit 查询都从这里过）
//          以及 HKQuantityType quantityTypeForIdentifier:，只记录、不篡改。
//          这样既能看到支付宝实际调了哪类查询（HKStatisticsCollectionQuery / HKSourceQuery /
//          HKAnchoredObjectQuery / HKStatisticsQuery ...），又把 swizzle 数量压到最低，避免闪退。
//  - 日志写到两处：全局 /var/mobile/hb_probe_<bundle>.log（最好找）+ App 沙盒 Documents/hb_probe.log。
//  - 所有文件写入都在主线程起来之后进行，constructor 内不做任何 IO，避免极早期 IO 引发不稳。
//
// 编译：xcrun --sdk iphoneos clang -dynamiclib -fobjc-arc \
//   -framework Foundation -framework CoreFoundation -framework CoreMotion -framework HealthKit \
//   -arch arm64 -arch arm64e -mios-version-min=13.0 -isysroot $SDK -o StepFaker.dylib tweak/StepFaker.m
// 签名：ldid -M -S StepFaker.dylib

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreMotion/CoreMotion.h>
#import <HealthKit/HealthKit.h>
#include <dlfcn.h>
#include <string.h>

// ============================================================================
// hook API：优先用 CydiaSubstrate / ElleKit 的 MSHookMessageEx
// ----------------------------------------------------------------------------
// 为什么必须改：arm64e（iPhone 14 Pro 的 A16）带 PAC 指针认证。objc_msgSend
// 派发方法时会对 IMP 做 ptrauth 校验，直接把裸 C 函数指针塞给
// method_setImplementation，签名不符就会崩 —— 表现为支付宝一注入就闪退。
// 实测取证：搬运工源里可用的「支付宝修改步数」(StepCount.dylib) 其未定义
// 符号里明确带 _MSHookMessageEx，而它能在 arm64e 上正常跑。
// CI（macOS runner）没有 CydiaSubstrate 可链接，故用 dlsym 在运行时解析；
// 设备上 Substrate/ElleKit 必然已加载，能取到；取不到再回退原生 runtime。
// ============================================================================
typedef void (*HBMSHookMessageExFn)(Class cls, SEL sel, IMP hook, IMP *old);
static HBMSHookMessageExFn HBMSHook = NULL;

// 统一的安全 hook 入口。成功返回 YES，并回填原实现到 origOut。
static BOOL HBHookInstance(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (HBMSHook) {
        IMP old = NULL;
        HBMSHook(cls, sel, replacement, &old);
        if (origOut) *origOut = old;
        return YES;
    }
    // 回退：原生 runtime（无 PAC 处理，仅在没有 Substrate 时兜底）
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, replacement);
    return YES;
}

static BOOL HBHookClass(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    if (HBMSHook) {
        IMP old = NULL;
        HBMSHook(cls, sel, replacement, &old);
        if (origOut) *origOut = old;
        return YES;
    }
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, replacement);
    return YES;
}

// 读取目标步数（0 = 不篡改，原样放行）。
static NSInteger HBReadFakeSteps(void) {
    @autoreleasepool {
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
                NSString *s = (__bridge NSString *)val;
                v = [s integerValue];
            }
            CFRelease(val);
            if (v > 0) return v;
        }
        return 0;
    }
}

// 全局日志路径
static NSString *HBGlobalProbePath(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) bid = @"unknown";
    bid = [bid stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return [NSString stringWithFormat:@"/var/mobile/hb_probe_%@.log", bid];
}

// 探测日志：写全局路径 + App Documents + NSLog
static void HBProbeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@ %@] %@\n", ts, proc, msg];

    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *gp = HBGlobalProbePath();
    if (![fm fileExistsAtPath:gp]) {
        [@"" writeToFile:gp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *gfh = [NSFileHandle fileHandleForWritingAtPath:gp];
    if (gfh) { [gfh seekToEndOfFile]; [gfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [gfh closeFile]; }

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    if (doc.length > 0) {
        NSString *p = [doc stringByAppendingPathComponent:@"hb_probe.log"];
        if (![fm fileExistsAtPath:p]) {
            NSString *header = [NSString stringWithFormat:
                @"StepFaker probe log.\nGlobal path = %@\nApp container Documents = %@\n\n", gp, doc];
            [header writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
    NSLog(@"[StepFaker] %@", msg);
}

static NSString *HBQueryTypeIdentifier(id query) {
    if ([query respondsToSelector:@selector(quantityType)]) {
        HKObjectType *t = [query quantityType];
        if ([t respondsToSelector:@selector(identifier)]) return [t identifier];
    }
    if ([query respondsToSelector:@selector(sampleType)]) {
        HKObjectType *t = [query sampleType];
        if ([t respondsToSelector:@selector(identifier)]) return [t identifier];
    }
    return nil;
}

static BOOL HBIsStepType(id type) {
    if (!type) return NO;
    HKObjectType *t = type;
    NSString *tid = [t respondsToSelector:@selector(identifier)] ? [t identifier] : nil;
    return [tid isEqualToString:@"HKQuantityTypeIdentifierStepCount"];
}

// 路径一：CMPedometerData.numberOfSteps（微信命中，1.0.131 验证可用）
static NSNumber *(*orig_numberOfSteps)(id, SEL) = NULL;
static NSNumber *new_numberOfSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) return @(fake);
    return orig_numberOfSteps(self, _cmd);
}

// 路径二：HKStatistics 聚合查询（支付宝，1.0.131）
static id (*orig_sumQ)(id, SEL) = NULL;
static id new_sumQ(id self, SEL _cmd) {
    if (HBIsStepType([self quantityType])) {
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
    if (HBIsStepType([self quantityType])) {
        NSInteger fake = HBReadFakeSteps();
        if (fake > 0) {
            HKUnit *unit = [HKUnit countUnit];
            return [HKQuantity quantityWithUnit:unit doubleValue:(double)fake];
        }
    }
    return orig_avgQ(self, _cmd);
}

// 路径三：HKSampleQuery 逐样本查询（支付宝，1.0.131）
static id (*orig_SQ_init)(id, SEL, id, id, unsigned long, id, id) = NULL;
static id new_SQ_init(id self, SEL _cmd,
                      id type, id pred, unsigned long limit, id sorts, id handler) {
    if (HBIsStepType(type)) {
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

// 路径四：支付宝 APStepInfo.numberOfSteps（long long）—— Flex 社区公认目标，支付宝运动步数走这里
// 与微信的 CMPedometerData 不同，支付宝用自己的内部类承载步数显示值。
static long long (*orig_apSteps)(id, SEL) = NULL;
static long long new_apSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) {
        static BOOL apLogged = NO;
        if (!apLogged) {
            apLogged = YES;
            HBProbeLog(@"ALIPAY_FAKE_RETURNED: APStepInfo.numberOfSteps returning fake=%ld", (long)fake);
        }
        return (long long)fake;
    }
    return orig_apSteps ? orig_apSteps(self, _cmd) : 0;
}

// 路径四之 setter：APStepInfo.setNumberOfSteps:(long long)
// 为什么要连 setter 一起 hook：支付宝可能是「先算出步数 → setNumberOfSteps: 存进 ivar →
// 之后直接读 ivar」的用法。那种情况下只 hook getter 会被彻底绕过，步数纹丝不动。
// 现成的「支付宝修改步数」(StepCount.dylib) 就是 getter + setter 一起 hook 的。
// 两边都兜住，无论它走 getter 还是读 ivar，拿到的都是假值。
static void (*orig_setApSteps)(id, SEL, long long) = NULL;
static void new_setApSteps(id self, SEL _cmd, long long steps) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) {
        static BOOL apSetLogged = NO;
        if (!apSetLogged) {
            apSetLogged = YES;
            HBProbeLog(@"ALIPAY_SET_FAKED: setNumberOfSteps: %lld -> %ld", steps, (long)fake);
        }
        steps = (long long)fake;   // 连写入的值一起改掉，覆盖直接读 ivar 的路径
    }
    if (orig_setApSteps) orig_setApSteps(self, _cmd, steps);
}

// ===== 探测（仅记录，不篡改）：唯一总入口 + 类型工厂 =====
static void (*orig_execQ)(id, SEL, id) = NULL;
static void new_execQ(id self, SEL _cmd, id query) {
    NSString *cls = NSStringFromClass([query class]);
    NSString *tid = HBQueryTypeIdentifier(query);
    HBProbeLog(@"HKHealthStore.executeQuery class=%@ type=%@", cls, tid ?: @"?");
    orig_execQ(self, _cmd, query);
}

static id (*orig_QTForId)(Class, SEL, NSString *) = NULL;
static id new_QTForId(Class self, SEL _cmd, NSString *identifier) {
    id r = orig_QTForId(self, _cmd, identifier);
    if ([identifier containsString:@"StepCount"] ||
        [identifier containsString:@"Walking"] ||
        [identifier containsString:@"Flights"]) {
        HBProbeLog(@"HKQuantityType.quantityTypeForIdentifier=%@ -> %@", identifier, r);
    }
    return r;
}

// ===== 探测（仅记录，不篡改）：CoreMotion 步数入口 =====
// 微信/支付宝可能走 CoreMotion 而非 HealthKit；加这组日志型 hook，
// 只记录调用了哪个入口 + 返回值，便于定位 支付宝 的真实路径（不猜接口）。
static void (*orig_queryPed)(id, SEL, id, id, id) = NULL;
static void new_queryPed(id self, SEL _cmd, id from, id to, id handler) {
    HBProbeLog(@"CMPedometer.queryPedometerDataFromDate:toDate:withHandler: called");
    if (handler) {
        id orig = handler;
        id newH = ^(CMPedometerData *data, NSError *err) {
            @autoreleasepool {
                if (data) HBProbeLog(@"  -> returned numberOfSteps=%@", [data numberOfSteps]);
                void (^h)(CMPedometerData*, NSError*) = orig;
                h(data, err);
            }
        };
        orig_queryPed(self, _cmd, from, to, newH);
        return;
    }
    orig_queryPed(self, _cmd, from, to, handler);
}

static void (*orig_startPed)(id, SEL, id, id) = NULL;
static void new_startPed(id self, SEL _cmd, id from, id handler) {
    HBProbeLog(@"CMPedometer.startPedometerUpdatesFromDate:withHandler: called");
    if (handler) {
        id orig = handler;
        id newH = ^(CMPedometerData *data, NSError *err) {
            @autoreleasepool {
                if (data) HBProbeLog(@"  -> live numberOfSteps=%@", [data numberOfSteps]);
                void (^h)(CMPedometerData*, NSError*) = orig;
                h(data, err);
            }
        };
        orig_startPed(self, _cmd, from, newH);
        return;
    }
    orig_startPed(self, _cmd, from, handler);
}

static void (*orig_stepCnt)(id, SEL, id, id, id, id) = NULL;
static void new_stepCnt(id self, SEL _cmd, id from, id to, id queue, id handler) {
    HBProbeLog(@"CMStepCounter.queryStepCountStartingFrom:to:toQueue:withHandler: called");
    if (handler) {
        id orig = handler;
        id newH = ^(NSInteger count, NSError *err) {
            @autoreleasepool {
                HBProbeLog(@"  -> returned steps=%ld", (long)count);
                void (^h)(NSInteger, NSError*) = orig;
                h(count, err);
            }
        };
        orig_stepCnt(self, _cmd, from, to, queue, newH);
        return;
    }
    orig_stepCnt(self, _cmd, from, to, queue, handler);
}

static void StepFakerTryHookCoreMotion(void) {
    static BOOL cmDone = NO;
    if (cmDone) return;
    Class pedCls = objc_getClass("CMPedometer");
    Class scCls  = objc_getClass("CMStepCounter");
    if (!pedCls && !scCls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookCoreMotion(); });
        return;
    }
    if (pedCls) {
        if (orig_queryPed == NULL) {
            HBHookInstance(pedCls, @selector(queryPedometerDataFromDate:toDate:withHandler:),
                           (IMP)new_queryPed, (IMP *)&orig_queryPed);
        }
        if (orig_startPed == NULL) {
            HBHookInstance(pedCls, @selector(startPedometerUpdatesFromDate:withHandler:),
                           (IMP)new_startPed, (IMP *)&orig_startPed);
        }
    }
    if (scCls && orig_stepCnt == NULL) {
        HBHookInstance(scCls, @selector(queryStepCountStartingFrom:to:toQueue:withHandler:),
                       (IMP)new_stepCnt, (IMP *)&orig_stepCnt);
    }
    cmDone = YES;
}

// ===== hook 安装 =====
static void StepFakerTryHookPedometer(void) {
    static BOOL pedDone = NO;
    if (pedDone) return;
    Class cls = objc_getClass("CMPedometerData");
    if (!cls) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookPedometer(); }); return; }
    Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
    if (!m) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookPedometer(); }); return; }
    if (orig_numberOfSteps == NULL) {
        HBHookInstance(cls, @selector(numberOfSteps), (IMP)new_numberOfSteps, (IMP *)&orig_numberOfSteps);
    }
    pedDone = YES;
}

static void StepFakerTryHookHK(void) {
    static BOOL hkDone = NO;
    if (hkDone) return;
    Class statCls = objc_getClass("HKStatistics");
    Class sqCls = objc_getClass("HKSampleQuery");
    if (!statCls && !sqCls) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookHK(); }); return; }
    if (statCls) {
        if (orig_sumQ == NULL) {
            HBHookInstance(statCls, @selector(sumQuantity), (IMP)new_sumQ, (IMP *)&orig_sumQ);
        }
        if (orig_avgQ == NULL) {
            HBHookInstance(statCls, @selector(averageQuantity), (IMP)new_avgQ, (IMP *)&orig_avgQ);
        }
    }
    if (sqCls && orig_SQ_init == NULL) {
        HBHookInstance(sqCls, @selector(initWithSampleType:predicate:limit:sortDescriptors:resultsHandler:),
                       (IMP)new_SQ_init, (IMP *)&orig_SQ_init);
    }
    hkDone = YES;
}

static void StepFakerTryHookProbe(void) {
    static BOOL probeDone = NO;
    if (probeDone) return;
    Class qtCls = objc_getClass("HKQuantityType");
    Class hsCls = objc_getClass("HKHealthStore");
    if (!qtCls || !hsCls) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookProbe(); }); return; }
    if (orig_QTForId == NULL) {
        HBHookClass(qtCls, @selector(quantityTypeForIdentifier:), (IMP)new_QTForId, (IMP *)&orig_QTForId);
    }
    if (orig_execQ == NULL) {
        HBHookInstance(hsCls, @selector(executeQuery:), (IMP)new_execQ, (IMP *)&orig_execQ);
    }
    probeDone = YES;
}

static void StepFakerTryHookAlipay(void) {
    static BOOL apDone = NO;
    if (apDone) return;
    Class cls = objc_getClass("APStepInfo");
    if (!cls) {
        // 支付宝的类可能延迟加载，1 秒后重试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookAlipay(); });
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
    if (m) {
        const char *ret = method_getTypeEncoding(m);
        // 'q' = long long，确保只 hook 返回 long long 的那一个 numberOfSteps
        if (ret && ret[0] == 'q') {
            if (HBHookInstance(cls, @selector(numberOfSteps), (IMP)new_apSteps, (IMP *)&orig_apSteps)) {
                HBProbeLog(@"ALIPAY_HOOK_INSTALLED: APStepInfo.numberOfSteps(long long) hooked");
            } else {
                HBProbeLog(@"ALIPAY_HOOK_FAILED: HBHookInstance returned NO");
            }
            HBProbeLog(@"BUILD_MARKER_XY7Q_PRESENT");
        } else {
            HBProbeLog(@"ALIPAY_HOOK_SKIPPED: APStepInfo.numberOfSteps ret type=%s (not 'q')", ret ? ret : "?");
        }
    } else {
        HBProbeLog(@"ALIPAY_NO_METHOD: APStepInfo has no numberOfSteps (Alipay version mismatch)");
    }

    // setter：兜住「set 进 ivar 之后直接读 ivar」的用法 —— 只 hook getter 会被绕过
    Method sm = class_getInstanceMethod(cls, @selector(setNumberOfSteps:));
    if (sm) {
        const char *senc = method_getTypeEncoding(sm);
        // 期望形如 v24@0:8q16：void 返回 + 一个 long long 参数
        if (senc && senc[0] == 'v' && strchr(senc, 'q')) {
            if (HBHookInstance(cls, @selector(setNumberOfSteps:), (IMP)new_setApSteps, (IMP *)&orig_setApSteps)) {
                HBProbeLog(@"ALIPAY_SETTER_HOOKED: APStepInfo.setNumberOfSteps: hooked");
            } else {
                HBProbeLog(@"ALIPAY_SETTER_FAILED: HBHookInstance returned NO");
            }
        } else {
            HBProbeLog(@"ALIPAY_SETTER_SKIPPED: setNumberOfSteps: enc=%s (expect v..q)", senc ? senc : "?");
        }
    } else {
        HBProbeLog(@"ALIPAY_NO_SETTER: APStepInfo has no setNumberOfSteps:");
    }
    apDone = YES;
}

__attribute__((constructor)) static void StepFakerInit(void) {
    // 解析 Substrate / ElleKit 的 MSHookMessageEx（arm64e 上唯一安全的 hook 方式）。
    // 注入器在加载 tweak 之前必然已经把 substrate 载入进程，RTLD_DEFAULT 一般即可取到；
    // 取不到再按 roothide / rootless 的常见路径 dlopen 兜底。
    HBMSHook = (HBMSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!HBMSHook) {
        static const char *cands[] = {
            "/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            NULL
        };
        for (int i = 0; cands[i] && !HBMSHook; i++) {
            void *h = dlopen(cands[i], RTLD_NOW);
            if (h) HBMSHook = (HBMSHookMessageExFn)dlsym(h, "MSHookMessageEx");
        }
    }
    // 同步写「已加载」记录：dylib 一旦被注入即刻落盘，最大限度确认注入是否真的发生。
    // （旧实现用 dispatch_async 主队列，若目标 App 主队列异常会不触发，导致「无日志」误判为未注入；
    //   改为同步后，只要 dylib 被加载，这行必写入。微信实测同步 IO 无不稳。）
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) bid = @"unknown";
        HBProbeLog(@"StepFaker PROBE loaded (safe mode), bundle=%@, globalLog=%@, MSHookMessageEx=%@, exe=%@",
            bid, HBGlobalProbePath(),
            HBMSHook ? @"YES" : @"NO(fallback)",
            [[[NSBundle mainBundle] executablePath] lastPathComponent] ?: @"?");
    }
    StepFakerTryHookPedometer();
    StepFakerTryHookHK();
    StepFakerTryHookProbe();
    StepFakerTryHookCoreMotion();
    StepFakerTryHookAlipay();
}
