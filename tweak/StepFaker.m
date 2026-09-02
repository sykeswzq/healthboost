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
    if (fake > 0) return (long long)fake;
    return orig_apSteps ? orig_apSteps(self, _cmd) : 0;
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
        Method m;
        if (orig_queryPed == NULL && (m = class_getInstanceMethod(pedCls, @selector(queryPedometerDataFromDate:toDate:withHandler:)))) {
            orig_queryPed = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_queryPed);
        }
        if (orig_startPed == NULL && (m = class_getInstanceMethod(pedCls, @selector(startPedometerUpdatesFromDate:withHandler:)))) {
            orig_startPed = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_startPed);
        }
    }
    if (scCls && orig_stepCnt == NULL) {
        Method m = class_getInstanceMethod(scCls, @selector(queryStepCountStartingFrom:to:toQueue:withHandler:));
        if (m) { orig_stepCnt = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_stepCnt); }
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
    if (orig_numberOfSteps == NULL) { orig_numberOfSteps = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_numberOfSteps); }
    pedDone = YES;
}

static void StepFakerTryHookHK(void) {
    static BOOL hkDone = NO;
    if (hkDone) return;
    Class statCls = objc_getClass("HKStatistics");
    Class sqCls = objc_getClass("HKSampleQuery");
    if (!statCls && !sqCls) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ StepFakerTryHookHK(); }); return; }
    if (statCls) {
        Method m;
        if (orig_sumQ == NULL && (m = class_getInstanceMethod(statCls, @selector(sumQuantity)))) { orig_sumQ = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_sumQ); }
        if (orig_avgQ == NULL && (m = class_getInstanceMethod(statCls, @selector(averageQuantity)))) { orig_avgQ = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_avgQ); }
    }
    if (sqCls && orig_SQ_init == NULL) {
        Method m = class_getInstanceMethod(sqCls, @selector(initWithSampleType:predicate:limit:sortDescriptors:resultsHandler:));
        if (m) { orig_SQ_init = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_SQ_init); }
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
        Method m = class_getClassMethod(qtCls, @selector(quantityTypeForIdentifier:));
        if (m) { orig_QTForId = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_QTForId); }
    }
    if (orig_execQ == NULL) {
        Method m = class_getInstanceMethod(hsCls, @selector(executeQuery:));
        if (m) { orig_execQ = (void*)method_getImplementation(m); method_setImplementation(m, (IMP)new_execQ); }
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
            orig_apSteps = (void*)method_getImplementation(m);
            method_setImplementation(m, (IMP)new_apSteps);
            HBProbeLog(@"HOOKED APStepInfo.numberOfSteps (支付宝步数入口, 返回 long long)");
        } else {
            HBProbeLog(@"APStepInfo.numberOfSteps 返回类型非 long long (%s)，跳过", ret ? ret : "?");
        }
    } else {
        HBProbeLog(@"APStepInfo 不含 numberOfSteps（可能支付宝版本不符）");
    }
    apDone = YES;
}

__attribute__((constructor)) static void StepFakerInit(void) {
    // 不在 constructor 里做文件 IO：等主线程起来后再写「已加载」记录，避免极早期 IO 引发不稳定
    dispatch_async(dispatch_get_main_queue(), ^{
        HBProbeLog(@"StepFaker PROBE loaded (safe mode), bundle=%@, globalLog=%@",
            [[NSBundle mainBundle] bundleIdentifier], HBGlobalProbePath());
    });
    StepFakerTryHookPedometer();
    StepFakerTryHookHK();
    StepFakerTryHookProbe();
    StepFakerTryHookCoreMotion();
    StepFakerTryHookAlipay();
}
