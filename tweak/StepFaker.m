// StepFaker —— 干净的注入式 tweak（探测版）
//
// 设计要点：
//   1) 微信运动 / 支付宝运动 显示的步数来源不同，目前已知：
//      - 微信：走 CoreMotion 的 CMPedometerData.numberOfSteps（实测命中）
//      - 支付宝：走 HealthKit 聚合查询路径（HKStatistics / HKSampleQuery），
//        但具体是哪一种仍待实测确认（不要瞎猜）。
//   2) 只注入 com.tencent.xin（微信）与 com.alipay.iphoneclient（支付宝），
//      绝不碰 SpringBoard / 本 App / 其他进程。
//   3) 目标步数由 HealthBoost App 写入：
//        - 通道A：写进微信/支付宝容器 Documents/hb_steps.txt
//        - 通道B：写进 CFPreferences 系统域 com.apple.mobile.healthboost / steps
//      tweak 跑在对应进程内读取；为 0 时原样放行。
//
// 本「探测版」新增能力：
//   - 在保持现有篡改逻辑的同时，hook 一整套 HealthKit/CoreMotion 步数相关 API，
//     把它们被调用的类名 / 类型 / 参数写进各进程 Documents/hb_probe.log（纯文本），
//     同时 NSLog。这样支付宝到底走哪条接口，跑一遍就能从日志里看清楚，
//     后续再按日志精准补 hook，而不是猜。
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

// ---------------------------------------------------------------------------
// 探测日志：同时写当前进程 Documents/hb_probe.log + 系统 NSLog
// ---------------------------------------------------------------------------
static void HBProbeLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@ %@] %@\n", ts, proc, msg];

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    if (doc.length > 0) {
        NSString *p = [doc stringByAppendingPathComponent:@"hb_probe.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:p]) {
            [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    NSLog(@"[StepFaker] %@", msg);
}

// 从任意 HKQuery 上安全取类型标识
static NSString *HBQueryTypeIdentifier(id query) {
    if ([query respondsToSelector:@selector(quantityType)]) {
        id t = [query quantityType];
        if ([t respondsToSelector:@selector(identifier)]) return [t identifier];
    }
    if ([query respondsToSelector:@selector(sampleType)]) {
        id t = [query sampleType];
        if ([t respondsToSelector:@selector(identifier)]) return [t identifier];
    }
    if ([query respondsToSelector:@selector(type)]) {
        id t = [query type];
        if ([t respondsToSelector:@selector(identifier)]) return [t identifier];
    }
    return nil;
}

static BOOL HBIsStepType(id type) {
    if (!type) return NO;
    NSString *tid = [type respondsToSelector:@selector(identifier)] ? [type identifier] : nil;
    return [tid isEqualToString:@"HKQuantityTypeIdentifierStepCount"];
}

// ---------------------------------------------------------------------------
// 路径一：CoreMotion 的 CMPedometerData.numberOfSteps（微信命中）
// ---------------------------------------------------------------------------
static NSNumber *(*orig_numberOfSteps)(id, SEL) = NULL;
static NSNumber *new_numberOfSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    HBProbeLog(@"CMPedometerData.numberOfSteps fake=%ld", (long)fake);
    if (fake > 0) return @(fake);
    return orig_numberOfSteps(self, _cmd);
}

// ---------------------------------------------------------------------------
// 路径二：HealthKit 的 HKStatistics 聚合查询（支付宝已有命中路径）
// ---------------------------------------------------------------------------
static id (*orig_sumQ)(id, SEL) = NULL;
static id new_sumQ(id self, SEL _cmd) {
    id type = [self quantityType];
    if (HBIsStepType(type)) {
        NSInteger fake = HBReadFakeSteps();
        HBProbeLog(@"HKStatistics.sumQuantity fake=%ld", (long)fake);
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
    if (HBIsStepType(type)) {
        NSInteger fake = HBReadFakeSteps();
        HBProbeLog(@"HKStatistics.averageQuantity fake=%ld", (long)fake);
        if (fake > 0) {
            HKUnit *unit = [HKUnit countUnit];
            return [HKQuantity quantityWithUnit:unit doubleValue:(double)fake];
        }
    }
    return orig_avgQ(self, _cmd);
}

// ---------------------------------------------------------------------------
// 探测：HKStatistics 其他聚合值（只记录，不篡改）
// ---------------------------------------------------------------------------
static id (*orig_minQ)(id, SEL) = NULL;
static id new_minQ(id self, SEL _cmd) {
    if (HBIsStepType([self quantityType])) HBProbeLog(@"HKStatistics.minimumQuantity HIT");
    return orig_minQ(self, _cmd);
}

static id (*orig_maxQ)(id, SEL) = NULL;
static id new_maxQ(id self, SEL _cmd) {
    if (HBIsStepType([self quantityType])) HBProbeLog(@"HKStatistics.maximumQuantity HIT");
    return orig_maxQ(self, _cmd);
}

static id (*orig_durationQ)(id, SEL) = NULL;
static id new_durationQ(id self, SEL _cmd) {
    if (HBIsStepType([self quantityType])) HBProbeLog(@"HKStatistics.duration HIT");
    return orig_durationQ(self, _cmd);
}

// ---------------------------------------------------------------------------
// 路径三：HealthKit 的 HKSampleQuery 逐样本查询（支付宝已有命中路径）
// ---------------------------------------------------------------------------
static id (*orig_SQ_init)(id, SEL, id, id, unsigned long, id, id) = NULL;
static id new_SQ_init(id self, SEL _cmd,
                      id type, id pred, unsigned long limit, id sorts, id handler) {
    if (HBIsStepType(type)) {
        NSInteger fake = HBReadFakeSteps();
        HBProbeLog(@"HKSampleQuery.init fake=%ld", (long)fake);
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
// 探测：HKQuantityType 创建
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// 探测：HKHealthStore executeQuery:（所有 HealthKit 查询都从这里过）
// ---------------------------------------------------------------------------
static void (*orig_execQ)(id, SEL, id) = NULL;
static void new_execQ(id self, SEL _cmd, id query) {
    NSString *cls = NSStringFromClass([query class]);
    NSString *tid = HBQueryTypeIdentifier(query);
    HBProbeLog(@"HKHealthStore.executeQuery class=%@ type=%@", cls, tid ?: @"?");
    orig_execQ(self, _cmd, query);
}

// ---------------------------------------------------------------------------
// 探测：各类 HKQuery 初始化（记录支付宝用的查询类型）
// ---------------------------------------------------------------------------
static id (*orig_statQ_init)(id, SEL, id, id, NSUInteger, id) = NULL;
static id new_statQ_init(id self, SEL _cmd, id type, id pred, NSUInteger opts, id handler) {
    HBProbeLog(@"HKStatisticsQuery.init type=%@ opts=%lu", [type identifier], (unsigned long)opts);
    return orig_statQ_init(self, _cmd, type, pred, opts, handler);
}

static id (*orig_statCollQ_init)(id, SEL, id, id, NSUInteger, id, id) = NULL;
static id new_statCollQ_init(id self, SEL _cmd, id type, id pred, NSUInteger opts, id anchor, id interval) {
    HBProbeLog(@"HKStatisticsCollectionQuery.init type=%@ opts=%lu", [type identifier], (unsigned long)opts);
    return orig_statCollQ_init(self, _cmd, type, pred, opts, anchor, interval);
}

static id (*orig_anchorQ_init)(id, SEL, id, id, id, NSUInteger, id) = NULL;
static id new_anchorQ_init(id self, SEL _cmd, id type, id pred, id anchor, NSUInteger limit, id handler) {
    HBProbeLog(@"HKAnchoredObjectQuery.init type=%@ limit=%lu", [type identifier], (unsigned long)limit);
    return orig_anchorQ_init(self, _cmd, type, pred, anchor, limit, handler);
}

static id (*orig_sourceQ_init)(id, SEL, id, id) = NULL;
static id new_sourceQ_init(id self, SEL _cmd, id type, id handler) {
    HBProbeLog(@"HKSourceQuery.init type=%@", [type identifier]);
    return orig_sourceQ_init(self, _cmd, type, handler);
}

static id (*orig_corrQ_init)(id, SEL, id, id, id, id) = NULL;
static id new_corrQ_init(id self, SEL _cmd, id type, id pred, id samplePreds, id handler) {
    HBProbeLog(@"HKCorrelationQuery.init type=%@", [type identifier]);
    return orig_corrQ_init(self, _cmd, type, pred, samplePreds, handler);
}

// ---------------------------------------------------------------------------
// 探测：HKStatisticsCollection 取值
// ---------------------------------------------------------------------------
static NSArray *(*orig_statColl_stats)(id, SEL) = NULL;
static NSArray *new_statColl_stats(id self, SEL _cmd) {
    NSArray *r = orig_statColl_stats(self, _cmd);
    HBProbeLog(@"HKStatisticsCollection.statistics count=%lu", (unsigned long)r.count);
    return r;
}

// ---------------------------------------------------------------------------
// 探测：CMPedometer 其他入口
// ---------------------------------------------------------------------------
static void (*orig_pedData)(id, SEL, id, id) = NULL;
static void new_pedData(id self, SEL _cmd, id date, id handler) {
    HBProbeLog(@"CMPedometer.queryPedometerDataFromDate:%@", date);
    orig_pedData(self, _cmd, date, handler);
}

static void (*orig_pedStepCount)(id, SEL, id, id, id) = NULL;
static void new_pedStepCount(id self, SEL _cmd, id from, id to, id handler) {
    HBProbeLog(@"CMPedometer.queryStepCountStartingFromDate:%@ toDate:%@", from, to);
    orig_pedStepCount(self, _cmd, from, to, handler);
}

static void (*orig_pedUpdates)(id, SEL, id, id) = NULL;
static void new_pedUpdates(id self, SEL _cmd, id date, id handler) {
    HBProbeLog(@"CMPedometer.startPedometerUpdatesFromDate:%@", date);
    orig_pedUpdates(self, _cmd, date, handler);
}

// ---------------------------------------------------------------------------
// 运行时 hook（带重试，因为 HealthKit 框架可能尚未加载）
// ---------------------------------------------------------------------------
static void StepFakerTryHookHealthKit(void) {
    static BOOL hkDone = NO;
    if (hkDone) return;

    Class statCls      = objc_getClass("HKStatistics");
    Class sqCls        = objc_getClass("HKSampleQuery");
    Class statQCls     = objc_getClass("HKStatisticsQuery");
    Class statCollQCls = objc_getClass("HKStatisticsCollectionQuery");
    Class anchorQCls   = objc_getClass("HKAnchoredObjectQuery");
    Class sourceQCls   = objc_getClass("HKSourceQuery");
    Class corrQCls     = objc_getClass("HKCorrelationQuery");
    Class statCollCls  = objc_getClass("HKStatisticsCollection");

    if (!statCls && !sqCls && !statQCls && !statCollQCls &&
        !anchorQCls && !sourceQCls && !corrQCls && !statCollCls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ StepFakerTryHookHealthKit(); });
        return;
    }

    if (statCls) {
        Method m;
        if (orig_sumQ == NULL && (m = class_getInstanceMethod(statCls, @selector(sumQuantity)))) {
            orig_sumQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_sumQ);
        }
        if (orig_avgQ == NULL && (m = class_getInstanceMethod(statCls, @selector(averageQuantity)))) {
            orig_avgQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_avgQ);
        }
        if (orig_minQ == NULL && (m = class_getInstanceMethod(statCls, @selector(minimumQuantity)))) {
            orig_minQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_minQ);
        }
        if (orig_maxQ == NULL && (m = class_getInstanceMethod(statCls, @selector(maximumQuantity)))) {
            orig_maxQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_maxQ);
        }
        if (orig_durationQ == NULL && (m = class_getInstanceMethod(statCls, @selector(duration)))) {
            orig_durationQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_durationQ);
        }
    }

    if (sqCls && orig_SQ_init == NULL) {
        Method m = class_getInstanceMethod(sqCls,
            @selector(initWithSampleType:predicate:limit:sortDescriptors:resultsHandler:));
        if (m) { orig_SQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_SQ_init); }
    }

    if (statQCls && orig_statQ_init == NULL) {
        Method m = class_getInstanceMethod(statQCls,
            @selector(initWithQuantityType:quantitySamplePredicate:options:completionHandler:));
        if (m) { orig_statQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_statQ_init); }
    }

    if (statCollQCls && orig_statCollQ_init == NULL) {
        Method m = class_getInstanceMethod(statCollQCls,
            @selector(initWithQuantityType:quantitySamplePredicate:options:anchorDate:intervalComponents:));
        if (m) { orig_statCollQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_statCollQ_init); }
    }

    if (anchorQCls && orig_anchorQ_init == NULL) {
        Method m = class_getInstanceMethod(anchorQCls,
            @selector(initWithType:predicate:anchor:limit:resultsHandler:));
        if (m) { orig_anchorQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_anchorQ_init); }
    }

    if (sourceQCls && orig_sourceQ_init == NULL) {
        Method m = class_getInstanceMethod(sourceQCls,
            @selector(initWithSampleType:samplePredicate:completionHandler:));
        if (m) { orig_sourceQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_sourceQ_init); }
    }

    if (corrQCls && orig_corrQ_init == NULL) {
        Method m = class_getInstanceMethod(corrQCls,
            @selector(initWithType:predicate:samplePredicates:completionHandler:));
        if (m) { orig_corrQ_init = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_corrQ_init); }
    }

    if (statCollCls) {
        Method m;
        if (orig_statColl_stats == NULL && (m = class_getInstanceMethod(statCollCls, @selector(statistics)))) {
            orig_statColl_stats = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_statColl_stats);
        }
    }

    hkDone = YES;
}

static void StepFakerTryHookPedometer(void) {
    static BOOL pedDone = NO;
    if (pedDone) return;
    Class cls   = objc_getClass("CMPedometerData");
    Class pedCls = objc_getClass("CMPedometer");
    if (!cls || !pedCls) {
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

    Method m2;
    if (orig_pedData == NULL && (m2 = class_getInstanceMethod(pedCls, @selector(queryPedometerDataFromDate:withHandler:)))) {
        orig_pedData = (void *)method_getImplementation(m2); method_setImplementation(m2, (IMP)new_pedData);
    }
    if (orig_pedStepCount == NULL && (m2 = class_getInstanceMethod(pedCls, @selector(queryStepCountStartingFromDate:toDate:withHandler:)))) {
        orig_pedStepCount = (void *)method_getImplementation(m2); method_setImplementation(m2, (IMP)new_pedStepCount);
    }
    if (orig_pedUpdates == NULL && (m2 = class_getInstanceMethod(pedCls, @selector(startPedometerUpdatesFromDate:withHandler:)))) {
        orig_pedUpdates = (void *)method_getImplementation(m2); method_setImplementation(m2, (IMP)new_pedUpdates);
    }
    pedDone = YES;
}

static void StepFakerTryHookProbe(void) {
    static BOOL probeDone = NO;
    if (probeDone) return;

    Class qtCls = objc_getClass("HKQuantityType");
    Class hsCls = objc_getClass("HKHealthStore");
    if (!qtCls || !hsCls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ StepFakerTryHookProbe(); });
        return;
    }

    if (orig_QTForId == NULL) {
        Method m = class_getClassMethod(qtCls, @selector(quantityTypeForIdentifier:));
        if (m) { orig_QTForId = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_QTForId); }
    }

    if (orig_execQ == NULL) {
        Method m = class_getInstanceMethod(hsCls, @selector(executeQuery:));
        if (m) { orig_execQ = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)new_execQ); }
    }

    probeDone = YES;
}

__attribute__((constructor)) static void StepFakerInit(void) {
    HBProbeLog(@"StepFaker PROBE loaded, bundle=%@",
        [[NSBundle mainBundle] bundleIdentifier]);
    StepFakerTryHookPedometer();
    StepFakerTryHookHealthKit();
    StepFakerTryHookProbe();
}
