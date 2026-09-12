// StepFaker —— 干净的注入式 tweak（微信步数伪造）
//
// 设计：
//  - 仅注入 com.tencent.xin（微信）。
//  - 微信步数伪造逻辑（已验证可用）：
//      * CMPedometerData.numberOfSteps（主通道）
//      * HKStatistics sumQuantity/averageQuantity（备用通道）
//      * HKSampleQuery 逐样本查询（备用通道）
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
// method_setImplementation，签名不符就会崩。
// 实测取证：搬运工源里可用的步数修改插件其未定义符号里明确带 _MSHookMessageEx，
// 而它能在 arm64e 上正常跑。CI（macOS runner）没有 CydiaSubstrate 可链接，故用 dlsym 在运行时解析；
// 设备上 Substrate/ElleKit 必然已加载，能取到；取不到再回退原生 runtime。
// ============================================================================
typedef void (*HBMSHookMessageExFn)(Class cls, SEL sel, IMP hook, IMP *old);
static HBMSHookMessageExFn HBMSHook = NULL;

// 宿主进程标识。

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

// 「今天」判断（本地时区）—— 仅用于诊断日志。
// v1.0.201 曾做过「非今天的值失效」，但实际根因是 App 保存设置时不写步数文件
// （v1.0.202 已改为保存即写入），过期失效反而导致「第二天生成前微信显示真实步数」。
// v1.0.202 语义：文件值 = 用户当前设定的虚拟步数增量，持续生效直到用户修改；
// 99999 / >200000 哨兵脏值仍在 HBReadVirtualSteps 里拦截。
static NSString *HBFakeTodayString(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

static BOOL HBFileIsToday(NSString *path) {
    if (!path) return NO;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attr) return NO;
    NSDate *mt = attr[NSFileModificationDate];
    if (!mt) return NO;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *a = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:mt];
    NSDateComponents *b = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:[NSDate date]];
    return (a.year == b.year && a.month == b.month && a.day == b.day);
}

// 解析步数文件：第一行是数字，第二行可选 date:YYYY-MM-DD。
// outFresh 仅用于诊断日志，不影响取值。
static void HBParseStepsFile(NSString *path, NSInteger *outVal, BOOL *outFresh) {
    *outVal = 0; *outFresh = NO;
    if (!path) return;
    NSString *c = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (c.length == 0) return;
    NSArray *lines = [c componentsSeparatedByString:@"\n"];
    *outVal = [lines.firstObject integerValue];
    BOOL fresh = NO;
    if (lines.count > 1) {
        NSString *second = [lines[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([second hasPrefix:@"date:"]) {
            fresh = [[second substringFromIndex:5] isEqualToString:HBFakeTodayString()];
        }
    }
    if (!fresh) fresh = HBFileIsToday(path);
    *outFresh = fresh;
}

// 读取虚拟步数增量（0 = 不篡改，原样放行真实步数）。
// v2.2.16：文件值 = 用户当前设定的【虚拟步数增量】，持续生效直到用户修改；
// 日期只进日志，不影响取值。
// 新逻辑：显示步数 = 真实步数 + 虚拟步数增量
static NSInteger HBReadVirtualSteps(void) {
    @autoreleasepool {
        // ① 进程自身容器里的 hb_steps.txt（微信容器由 App 写入）
        NSInteger fileVal = 0;
        BOOL fileFresh = NO;
        NSString *filePath = nil;
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = paths.firstObject;
        if (doc.length > 0) {
            filePath = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
            HBParseStepsFile(filePath, &fileVal, &fileFresh);
        }
        // ② 共享通道：App 把假步数统一写到用户 home 的
        //    /var/mobile/Documents/hb_steps.txt，任何进程都能直接读到，
        //    不依赖各 App 自身沙盒容器。
        NSInteger sharedVal = 0;
        BOOL sharedFresh = NO;
        HBParseStepsFile(@"/var/mobile/Documents/hb_steps.txt", &sharedVal, &sharedFresh);
        NSInteger fileValEffective = (sharedVal > 0) ? sharedVal : fileVal;

        NSInteger cfVal = 0;
        BOOL cfFresh = NO;
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
        CFPropertyListRef dateVal = CFPreferencesCopyValue(
            CFSTR("stepsDate"),
            CFSTR("com.apple.mobile.healthboost"),
            kCFPreferencesAnyUser,
            kCFPreferencesAnyHost);
        if (dateVal) {
            if (CFGetTypeID(dateVal) == CFStringGetTypeID()) {
                cfFresh = [(__bridge NSString *)dateVal isEqualToString:HBFakeTodayString()];
            }
            CFRelease(dateVal);
        }
        // 优先共享文件，其次进程容器文件，最后 CFPreferences；日期仅诊断不参与判断
        NSInteger result = (fileValEffective > 0) ? fileValEffective : cfVal;
        HBProbeLog(@"READ_FAKE: sharedFile=%ld(today=%d) selfFile=%ld(today=%d) cfPref=%ld(today=%d) -> using=%ld",
                   (long)sharedVal, sharedFresh, (long)fileVal, fileFresh, (long)cfVal, cfFresh, (long)result);
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
// 之前 HBProbeLog 就是靠这些 Foundation API 写日志的，于是一旦在
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

    // 写两处：按进程名那份（便于区分微信/其他进程）+ 固定名兜底（路径算不出来也能找到）
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
// 新逻辑：显示 = 真实步数(orig) + 虚拟步数(增量)
static NSNumber *(*orig_numberOfSteps)(id, SEL) = NULL;
static NSNumber *new_numberOfSteps(id self, SEL _cmd) {
    NSNumber *real = orig_numberOfSteps ? orig_numberOfSteps(self, _cmd) : nil;
    NSInteger virtual = HBReadVirtualSteps();
    HBProbeLog(@"NUM_STEPS: real=%@ virtual=%ld -> 返回 real+virtual", real, (long)virtual);
    if (virtual > 0 && real != nil) {
        long total = (long)[real longValue] + (long)virtual;
        return @(total);
    }
    return real;
}

// 路径二：HKStatistics 聚合查询（备用通道）
static id (*orig_sumQ)(id, SEL) = NULL;
static id new_sumQ(id self, SEL _cmd) {
    if (HBIsStepType([self quantityType])) {
        NSInteger fake = HBReadVirtualSteps();
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
    id result = orig_avgQ ? orig_avgQ(self, _cmd) : nil;
    if (HBIsStepType([self quantityType])) {
        if (result && [result isKindOfClass:[HKStatistics class]]) {
            HKQuantity *q = [(HKStatistics *)result averageQuantity];
            if (q) {
                NSInteger v = HBReadVirtualSteps();
                if (v > 0) {
                    static BOOL avgLogged = NO;
                    if (!avgLogged) {
                        avgLogged = YES;
                        HBProbeLog(@"HKSTAT_AVG: real=%@ virtual=%ld -> 返回 real+virtual", q, (long)v);
                    }
                    HKUnit *unit = [HKUnit countUnit];
                    double nv = [q doubleValueForUnit:unit] + (double)v;
                    return [HKQuantity quantityWithUnit:unit doubleValue:nv];
                }
            }
        }
    }
    return result;
}

// 路径三：HKSampleQuery 逐样本查询（备用通道）
// 新逻辑：在 handler 回调中累加虚拟步数
// HKSampleQuery resultsHandler block 类型
typedef void (^HBHKSampleHandler)(HKSample * _Nullable sample,
                                  HKSample * _Nullable latestSample,
                                  NSInteger totalCount,
                                  NSError * _Nullable error);
static id (*orig_SQ_init)(id, SEL, id, id, unsigned long, id, id) = NULL;
static id new_SQ_init(id self, SEL _cmd,
                      id type, id pred, unsigned long limit, id sorts, id handler) {
    if (handler && type && [type isKindOfClass:[HKSampleType class]]) {
        NSString *tid = [(HKSampleType *)type identifier];
        if ([tid isEqualToString:HKQuantityTypeIdentifierStepCount]) {
            // 包装 handler，注入虚拟步数
            id wrapped = ^(HKSample * _Nullable sample, HKSample * _Nullable latestSample, NSInteger totalCount, NSError * _Nullable error) {
                @autoreleasepool {
                    if (sample && [sample isKindOfClass:[HKQuantitySample class]]) {
                        HKQuantitySample *qs = (HKQuantitySample *)sample;
                        NSInteger v = HBReadVirtualSteps();
                        if (v > 0) {
                            double cur = [qs.quantity doubleValueForUnit:[HKUnit countUnit]];
                            double nv = cur + (double)v;
                            sample = [HKQuantitySample quantitySampleWithType:qs.quantityType
                                                                       quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:nv]
                                                                     startDate:qs.startDate
                                                                       endDate:qs.endDate];
                            static BOOL sqLogged = NO;
                            if (!sqLogged) {
                                sqLogged = YES;
                                HBProbeLog(@"HKSAMPLE_QUERY: real=%@ virtual=%ld -> 返回 real+virtual", qs.quantity, (long)v);
                            }
                        }
                    }
                    if (handler) ((HBHKSampleHandler)handler)(sample, latestSample, totalCount, error);
                }
            };
            return orig_SQ_init(self, _cmd, type, pred, limit, sorts, wrapped);
        }
    }
    return orig_SQ_init(self, _cmd, type, pred, limit, sorts, handler);
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
// 微信可能走 CoreMotion 而非 HealthKit；加这组日志型 hook，
// 只记录调用了哪个入口 + 返回值，便于定位真实路径（不猜接口）。
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
    const char *prog = getprogname();    // 同步到文件级开关：入口闸门读的是它。
    HBRawLog("P2_PROG=%s", prog ? prog : "?");

    // 注入诊断（v1.0.200）：增强版
    // 1) 确认 dylib 是否真的加载进目标进程
    // 2) 同时写到 /var/mobile/Documents/ 和 /var/mobile/ 根（rootless 下均可写）
    // 3) 写入后确认日志是否成功，方便区分「没注入」vs「注入但写不了日志」
    {
        char inj[640];
        const char *pn = prog ? prog : "unknown";
        // 写 /var/mobile/ 根
        char root_path[256];
        snprintf(root_path, sizeof(root_path), "/var/mobile/hb_probe_inject_%s.log", pn);
        snprintf(inj, sizeof(inj), "[INJ-V2] %s injected_at=%lld\n", pn, (long long)time(NULL));
        int fd = open(root_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, inj, (unsigned)strlen(inj)); close(fd); }
        else { HBRawLog("INJ_LOG_FAIL: cannot write to %s (err=%d)", root_path, errno); }
        // 写 /var/mobile/Documents/
        snprintf(inj, sizeof(inj), "[INJ-V2] %s injected_at=%lld\n", pn, (long long)time(NULL));
        fd = open("/var/mobile/Documents/hb_inject.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, inj, (unsigned)strlen(inj)); close(fd); }
        else { HBRawLog("INJ_LOG_FAIL: cannot write to Documents/hb_inject.log (err=%d)", errno); }
        HBRawLog("INJ_PROBE_DONE: prog=%s", pn);
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
    HBRawLog("P9_DONE_WECHAT");
}
