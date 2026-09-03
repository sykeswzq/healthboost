// StepFaker —— 干净的注入式 tweak（安全探测版 1.0.136，补全 CoreMotion 入口探针）
//
// 设计：
//  - 仅注入 com.tencent.xin（微信）。
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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/time.h>

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

// 前向声明：下列日志函数在文件后段定义，前置声明以避免「调用未声明函数」编译错误。
static void HBRawLog(const char *fmt, ...);
static void HBProbeLog(NSString *fmt, ...);

// 读取目标步数（0 = 不篡改，原样放行）。
// v1.0.159：增加「值来源」诊断日志，定位 99999 到底来自文件还是 CFPreferences。
static NSInteger HBReadFakeSteps(void) {
    @autoreleasepool {
        // ① 进程自身容器里的 hb_steps.txt（微信容器由 App 写入；支付宝容器一般没有）
        NSInteger fileVal = 0;
        NSString *filePath = nil;
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = paths.firstObject;
        if (doc.length > 0) {
            NSString *p = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
            filePath = p;
            NSString *c = [NSString stringWithContentsOfFile:p
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
            if (c.length > 0) {
                NSString *line = [[c componentsSeparatedByString:@"\n"] firstObject];
                fileVal = [line integerValue];
            }
        }
        // ② 共享通道（v1.0.164 新增）：App 把假步数统一写到用户 home 的
        //    /var/mobile/Documents/hb_steps.txt，任何进程（含支付宝）都能直接读到，
        //    不依赖各 App 自身沙盒容器。这是支付宝拿到假值的唯一可靠来源。
        NSInteger sharedVal = 0;
        {
            NSString *sp = @"/var/mobile/Documents/hb_steps.txt";
            NSString *sc = [NSString stringWithContentsOfFile:sp
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
            if (sc.length > 0) {
                NSString *line = [[sc componentsSeparatedByString:@"\n"] firstObject];
                sharedVal = [line integerValue];
            }
        }
        NSInteger fileValEffective = (sharedVal > 0) ? sharedVal : fileVal;

        NSInteger cfVal = 0;
        CFPropertyListRef val = CFPreferencesCopyValue(
            CFSTR("steps"),
            CFSTR("com.apple.mobile.healthboost"),
            kCFPreferencesAnyUser,
            kCFPreferencesAnyHost);
        if (val) {
            if (CFGetTypeID(val) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)val, kCFNumberNSIntegerType, &cfVal);
            } else if (CFGetTypeID(val) == CFStringGetTypeID()) {
                cfVal = [(__bridge NSString *)val integerValue];
            }
            CFRelease(val);
        }
        // 优先共享文件，其次进程容器文件，再次 CFPreferences；三路都打印，便于定位 99999 来源
        NSInteger result = (fileValEffective > 0) ? fileValEffective : cfVal;
        HBProbeLog(@"READ_FAKE: sharedFile=%ld selfFile=%ld cfPref=%ld -> using=%ld",
                   (long)sharedVal, (long)fileVal, (long)cfVal, (long)result);
        // 防御：99999 是支付宝的异常/兜底哨兵值（非用户真实意图）；>200000 视为离谱脏值。
        // 正常伪造步数（含 9万~20万）不受影响，仅拦截确切 99999 与明显异常值。
        if (result == 99999 || result > 200000 || result <= 0) {
            HBProbeLog(@"READ_FAKE_IGNORE: value=%ld 疑似残留脏值/哨兵，跳过伪造（显示真实步数）", (long)result);
            return 0;
        }
        return result;
    }
}

// ============================================================================
// 极早期原始日志 HBRawLog —— 纯 POSIX，绝不触碰 Objective-C / Foundation
// ----------------------------------------------------------------------------
// 为什么必须有它：constructor 是 dyld 的 initializer，运行在 App 的 main()
// 之前。那个阶段 Foundation（NSDateFormatter / NSProcessInfo / NSFileManager /
// NSLog）可能尚未初始化完毕，调用它们会在部分 App 里直接崩溃。
// 之前 HBProbeLog 就是靠这些 Foundation API 写日志的，于是一旦在支付宝的
// constructor 阶段触发，进程当场挂掉、一个字都写不出来 —— 表现为
// 「一注入就闪退 + 完全没有任何日志」，极易被误判成「根本没注入」。
// 这里只用 open/write/close/gettimeofday/getprogname，零 ObjC 依赖，
// 因此能作为 dylib 的第一条语句安全执行，用来给崩溃点做「分步打点」定位。
// ============================================================================
static char g_rawPath[512] = {0};

static void HBRawWritePath(const char *path, const char *data, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, data, len);
    close(fd);
}

static void HBRawLog(const char *fmt, ...) {
    // 用可执行文件名（POSIX getprogname）而不是 NSBundle，避免依赖 Foundation
    if (!g_rawPath[0]) {
        const char *prog = getprogname();
        if (!prog || !*prog) prog = "unknown";
        snprintf(g_rawPath, sizeof(g_rawPath), "/var/mobile/hb_probe_%s.log", prog);
        for (char *p = g_rawPath; *p; p++) if (*p == '.') *p = '_';
    }

    char body[1024];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int)sizeof(body) - 1) n = (int)sizeof(body) - 1;

    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
    char line[1200];
    int total = snprintf(line, sizeof(line), "[%02d:%02d:%02d.%03d %s] ",
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                         (int)(tv.tv_usec / 1000),
                         getprogname() ? getprogname() : "?");
    if (total < 0 || total >= (int)sizeof(line)) total = 0;
    int room = (int)sizeof(line) - total - 2;
    if (n > room) n = room;
    memcpy(line + total, body, (size_t)n);
    total += n;
    line[total++] = '\n';
    line[total] = '\0';

    // 写两处：按进程名那份（便于区分微信/支付宝）+ 固定名兜底（路径算不出来也能找到）
    HBRawWritePath(g_rawPath, line, (size_t)total);
    HBRawWritePath("/var/mobile/hb_probe_raw.log", line, (size_t)total);
}

// 全局日志路径
static NSString *HBGlobalProbePath(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) bid = @"unknown";
    bid = [bid stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return [NSString stringWithFormat:@"/var/mobile/hb_probe_%@.log", bid];
}

// POSIX 时间戳（替代 NSDateFormatter：后者在 constructor 阶段可能触发 ICU/
// 时区数据加载而崩溃，是「闪退且无日志」的元凶之一）。
static NSString *HBTimeStamp(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d",
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000)];
}

// 探测日志：先写纯 POSIX 日志（零 Foundation 依赖），再写全局路径 + Documents + NSLog。
// 先写 raw 是关键：万一后面的 Foundation 调用崩溃，痕迹已经落盘，不会「零日志」。
static void HBProbeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    HBRawLog("OBJC %s", [msg UTF8String] ?: "?");

    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSString *ts = HBTimeStamp();
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
            static BOOL sumLogged = NO;
            if (!sumLogged) {
                sumLogged = YES;
                HBProbeLog(@"HKSTAT_SUM: returning fake=%ld", (long)fake);
            }
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
            static BOOL avgLogged = NO;
            if (!avgLogged) {
                avgLogged = YES;
                HBProbeLog(@"HKSTAT_AVG: returning fake=%ld", (long)fake);
            }
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
            static BOOL sqLogged = NO;
            if (!sqLogged) {
                sqLogged = YES;
                HBProbeLog(@"HKSAMPLE_QUERY: intercepting step query, returning fake=%ld", (long)fake);
            }
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

// ===== 方案 A+B：支付宝步数类自动探测 + 全量扫描兜底 =====
//
// 背景：支付宝每次大版本可能重命名/删除内部步数类（如 APStepInfo → 新名字）。
// 旧代码硬编码 "APStepInfo"，一旦类被改名，hook 就彻底失效 → 99999 重现。
//
// 本函数两件事一起做：
//   (A) 硬编码兜底：仍优先 hook 已知的 APStepInfo（最小侵入，兼容旧版支付宝）
//   (B) 动态扫描：遍历当前进程全部已注册类，找出所有「numberOfSteps 返回 long long」
//         和「setNumberOfSteps: 接收 long long 参数」的类，全部 hook 上。
//       这样无论支付宝把类改成什么名字，只要方法签名不变，hook 就永远有效。
//
//   额外日志（B 的配套）：每次扫描都把「发现的候选类名 + hook 结果 + 方法签名」
//         追加到 /var/mobile/Documents/hb_inject.log，便于以后诊断支付宝大版本更新
//         后 hook 是否还命中。
//
// 安全性：扫描全部类只在 constructor 做一次（进程启动时），不影响运行时性能。
//        扫描范围严格限定为「numberOfSteps/setNumberOfSteps:」两个 selector，
//        不会误 hook 其他无关方法。

static void HBLogInjectScanForAlipayClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    // C 数组收集候选类（避免 NSMutableArray<Class*> 泛型限制）
    static Class numStepsCandidates[200];
    static Class setNumStepsCandidates[200];
    int numCount = 0, setCount = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
        if (m && numCount < 200) {
            const char *enc = method_getTypeEncoding(m);
            if (enc && enc[0] == 'q') {
                numStepsCandidates[numCount++] = cls;
                HBProbeLog(@"SCAN_FOUND_numberOfSteps: class=%s enc=%s",
                           NSStringFromClass(cls).UTF8String, enc);
            }
        }

        Method sm = class_getInstanceMethod(cls, @selector(setNumberOfSteps:));
        if (sm && setCount < 200) {
            const char *se = method_getTypeEncoding(sm);
            if (se && strchr(se, 'q')) {
                setNumStepsCandidates[setCount++] = cls;
                HBProbeLog(@"SCAN_FOUND_setNumberOfSteps: class=%s enc=%s",
                           NSStringFromClass(cls).UTF8String, se);
            }
        }
    }
    free(classes);

    {
        FILE *f = fopen("/var/mobile/Documents/hb_inject.log", "a");
        if (f) {
            fprintf(f, "
[SCAN] numberOfSteps candidates (%d):
", numCount);
            for (int i = 0; i < numCount; i++) {
                Method m = class_getInstanceMethod(numStepsCandidates[i], @selector(numberOfSteps));
                const char *enc = m ? method_getTypeEncoding(m) : "?";
                fprintf(f, "  - %s  enc=%s
", NSStringFromClass(numStepsCandidates[i]).UTF8String, enc);
            }
            fprintf(f, "[SCAN] setNumberOfSteps: candidates (%d):
", setCount);
            for (int i = 0; i < setCount; i++) {
                Method sm = class_getInstanceMethod(setNumStepsCandidates[i], @selector(setNumberOfSteps:));
                const char *se = sm ? method_getTypeEncoding(sm) : "?";
                fprintf(f, "  - %s  enc=%s
", NSStringFromClass(setNumStepsCandidates[i]).UTF8String, se);
            }
            fclose(f);
        }
    }
}

static void StepFakerTryHookAlipay(void) {
    static BOOL apDone = NO;
    if (apDone) return;
    apDone = YES; // 防重复执行

    // ---- B：先做一次全量扫描，把候选类名全部记日志 ----
    HBLogInjectScanForAlipayClasses();

    // ---- A1：硬编码兜底 APStepInfo（兼容旧版支付宝） ----
    Class cls = objc_getClass("APStepInfo");
    if (!cls) {
        HBProbeLog(@"ALIPAY_CLASS_MISSING: APStepInfo not found in this Alipay version");
        HBRawLog("ALIPAY_CLASS_MISSING: APStepInfo not found — dynamic scan above shows actual candidates");
    }

    if (cls) {
        Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
        if (m) {
            const char *ret = method_getTypeEncoding(m);
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
            HBProbeLog(@"ALIPAY_NO_METHOD: APStepInfo has no numberOfSteps");
        }

        // setter
        Method sm = class_getInstanceMethod(cls, @selector(setNumberOfSteps:));
        if (sm) {
            const char *senc = method_getTypeEncoding(sm);
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
    }

    // ---- A2：动态扫描兜底 —— 对所有「numberOfSteps 返回 long long」的类也 hook ----
    // 覆盖支付宝大版本改名后 APStepInfo 消失的情况
    unsigned int scannedCount = 0;
    Class *allClasses = objc_copyClassList(&scannedCount);
    if (allClasses) {
        NSInteger extraHooked = 0;
        for (unsigned int i = 0; i < scannedCount; i++) {
            Class c = allClasses[i];
            if (!c) continue;
            // 跳过已知类（避免重复 hook）
            if (cls && c == cls) continue;

            Method m = class_getInstanceMethod(c, @selector(numberOfSteps));
            if (m) {
                const char *enc = method_getTypeEncoding(m);
                if (enc && enc[0] == 'q') {
                    if (HBHookInstance(c, @selector(numberOfSteps), (IMP)new_apSteps, NULL)) {
                        extraHooked++;
                        HBProbeLog(@"ALIPAY_DYNAMIC_HOOK: %s.numberOfSteps(long long) also hooked",
                                   NSStringFromClass(c));
                    }
                }
            }
        }
        free(allClasses);
        if (extraHooked > 0) {
            HBRawLog("ALIPAY_DYNAMIC_EXTRA_HOOKED=%ld (APStepInfo may have been renamed)", (long)extraHooked);
        }
    }

    // ---- A3：同样扫描 setNumberOfSteps: 的其它类 ----
    Class *scanned2 = objc_copyClassList(&scannedCount);
    if (scanned2) {
        NSInteger setExtra = 0;
        for (unsigned int i = 0; i < scannedCount; i++) {
            Class c = scanned2[i];
            if (!c) continue;
            if (cls && c == cls) continue;

            Method sm = class_getInstanceMethod(c, @selector(setNumberOfSteps:));
            if (sm) {
                const char *se = method_getTypeEncoding(sm);
                if (se && se[0] == 'v' && strchr(se, 'q')) {
                    if (HBHookInstance(c, @selector(setNumberOfSteps:), (IMP)new_setApSteps, NULL)) {
                        setExtra++;
                        HBProbeLog(@"ALIPAY_DYNAMIC_SET_HOOK: %s.setNumberOfSteps: also hooked",
                                   NSStringFromClass(c));
                    }
                }
            }
        }
        free(scanned2);
        if (setExtra > 0) {
            HBRawLog("ALIPAY_DYNAMIC_SET_EXTRA_HOOKED=%ld", (long)setExtra);
        }
    }

    // 最终汇总日志
    if (!cls) {
        HBRawLog("ALIPAY_FALLBACK_ONLY: APStepInfo absent, relying on dynamic scan results above");
    } else {
        HBRawLog("ALIPAY_APStepInfo_found=YES dynamic_scan_done");
    }
}

__attribute__((constructor)) static void StepFakerInit(void) {
    // ---- P0：整个 dylib 的第一条语句。只要 dylib 被 dyld 加载，这行必定落盘。----
    // 若连 P0 都没有：崩溃发生在 dyld 加载阶段（签名/架构/依赖/反注入），与 hook 无关。
    // 若 P0 有、后面的 P 缺失：崩溃就发生在最后一个已打印的 P 之后 —— 精确定位。
    HBRawLog("P0_ENTER dylib constructor entered");

    // ---- P1：安全模式开关 ----
    // 真机上 `touch /var/mobile/hb_nohook` 后重启 App：只写日志、不装任何 hook。
    // 用它一次性区分「崩溃来自注入本身」还是「崩溃来自某个 hook」。
    int safeMode = (access("/var/mobile/hb_nohook", F_OK) == 0);
    HBRawLog("P1_SAFEMODE=%d (file /var/mobile/hb_nohook %s)",
             safeMode, safeMode ? "exists -> skip ALL hooks" : "absent");

    // ---- P2：识别宿主进程（纯 POSIX，不用 NSBundle）----
    // 重要：isAlipay 必须根据进程名正确置位，否则支付宝会误走微信分支，
    // 把 HKSampleQuery 等假样本 hook 全装上，支付宝累加后截断成 99999。
    const char *prog = getprogname();
    int isAlipay = 0;
    if (prog && (strstr(prog, "Alipay") != NULL || strstr(prog, "alipay") != NULL)) {
        isAlipay = 1;
    }
    HBRawLog("P2_PROG=%s isAlipay=%d", prog ? prog : "?", isAlipay);

    // 注入诊断（v1.0.164）：把「dylib 是否进入本进程」写到用户 home Documents（纯 POSIX，constructor 阶段安全）。
    // 支付宝沙盒可能禁止写 /var/mobile 根目录，但 /var/mobile/Documents 是用户目录通常可写；
    // 若支付宝进程出现 [INJ] ... isAlipay=1，说明 dylib 已注入；若完全没有，说明 plist 过滤未命中。
    {
        char inj[640];
        snprintf(inj, sizeof(inj), "[INJ] %s isAlipay=%d\n", prog ? prog : "?", isAlipay);
        int fd = open("/var/mobile/Documents/hb_inject.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, inj, (unsigned)strlen(inj)); close(fd); }
    }

    // ---- P3：解析 Substrate / ElleKit 的 MSHookMessageEx ----
    // arm64e 有 PAC 指针认证，只有 MSHookMessageEx 能安全替换 IMP；
    // 裸 method_setImplementation 会在 objc_msgSend 派发时 ptrauth 校验失败而崩。
    // 取不到就按常见的 rootless / roothide 路径 dlopen 兜底。
    HBMSHook = (HBMSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    HBRawLog("P3A_DLSYM_DEFAULT=%d", HBMSHook ? 1 : 0);
    if (!HBMSHook) {
        static const char *cands[] = {
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/usr/lib/libsubstrate.dylib",
            NULL
        };
        for (int i = 0; cands[i] && !HBMSHook; i++) {
            void *h = dlopen(cands[i], RTLD_NOW);
            HBRawLog("P3B_DLOPEN %s -> %d", cands[i], h ? 1 : 0);
            if (h) HBMSHook = (HBMSHookMessageExFn)dlsym(h, "MSHookMessageEx");
        }
    }
    HBRawLog("P3_SUBSTRATE=%d", HBMSHook ? 1 : 0);

    if (safeMode) {
        HBRawLog("P9_DONE_NOHOOK safe mode: no hook installed");
        return;
    }

    // ---- P4+：安装 hook ----
    // 支付宝走「最小侵入」：只 hook APStepInfo。
    // 理由：CoreMotion / HealthKit 那套是给微信验证过的，但在支付宝里每多一个
    // swizzle 就多一分触发其完整性校验的风险；先把侵入面压到最小，
    // 确认 APStepInfo 这条路能通，再谈要不要加别的。
    if (isAlipay) {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        HBRawLog("P4_ALIPAY minimal footprint: hook APStepInfo only");
        HBProbeLog(@"P4_ALIPAY: isAlipay=1 prog=%s bid=%@ -> hook APStepInfo only",
                   prog ? prog : "?", bid ?: @"?");
        StepFakerTryHookAlipay();
        HBRawLog("P5_ALIPAY hook done");
        HBProbeLog(@"P9_DONE_ALIPAY");
        return;
    }

    // 微信等其它宿主：保持已验证稳定的全套逻辑
    HBRawLog("P4_WECHAT before pedometer hook");
    StepFakerTryHookPedometer();
    HBRawLog("P5_WECHAT after pedometer");
    StepFakerTryHookHK();
    HBRawLog("P6_WECHAT after HK");
    StepFakerTryHookProbe();
    HBRawLog("P7_WECHAT after probe");
    StepFakerTryHookCoreMotion();
    HBRawLog("P8_WECHAT after CoreMotion");
    StepFakerTryHookAlipay();
    HBRawLog("P9_DONE_WECHAT");
}
