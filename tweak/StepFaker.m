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

// 宿主进程标识。支付宝的整套 hook（含方案 A 的动态兜底）只允许在支付宝进程里装。
// 微信分支末尾也会调到 StepFakerTryHookAlipay()，没有这个闸门的话，
// 动态扫描会把微信自己的类当成「App 自有类」一并 hook —— 那是 1.0.166 微信闪退的根因。

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
// v1.0.202 语义：文件值 = 用户当前设定的目标步数，持续生效直到用户修改；
// 99999 / >200000 哨兵脏值仍在 HBReadFakeSteps 里拦截。
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

// 读取目标步数（0 = 不篡改，原样放行）。
// v1.0.202：文件值 = 当前目标，不限「今天」；日期只进日志。
static NSInteger HBReadFakeSteps(void) {
    @autoreleasepool {
        // ① 进程自身容器里的 hb_steps.txt（微信容器由 App 写入；支付宝容器一般没有）
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
        // ② 共享通道（v1.0.164 新增）：App 把假步数统一写到用户 home 的
        //    /var/mobile/Documents/hb_steps.txt，任何进程（含支付宝）都能直接读到，
        //    不依赖各 App 自身沙盒容器。这是支付宝拿到假值的唯一可靠来源。
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

// 与微信的 CMPedometerData 不同，支付宝用自己的内部类承载步数显示值。
static long long (*orig_apSteps)(id, SEL) = NULL;
static long long new_apSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) {
        static BOOL apLogged = NO;
        if (!apLogged) {
            apLogged = YES;
                    }
        return (long long)fake;
    }
    return orig_apSteps ? orig_apSteps(self, _cmd) : 0;
}

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

// ===== 方案 A2/A3：动态扫描命中类的「通用兜底 hook」 =====
// orig 必须按类分别保存，否则后 hook 的类会覆盖前面类的 orig，
// 一旦假值关闭（fake==0）就会跳到错误的原始实现 -> 崩溃。
// 这里用一张小表按类存 orig，查不到时沿 superclass 向上找（兼容 KVO 子类）。
#define HB_DYN_MAX 64

// 本文件用 -fobjc-arc 编译：结构体成员必须显式 __unsafe_unretained，
// 否则 ARC 会拒绝「结构体持有可保留对象指针」。
typedef struct { Class __unsafe_unretained cls; long long (*orig)(id, SEL); } HBDynGetter;
typedef struct { Class __unsafe_unretained cls; void (*orig)(id, SEL, long long); } HBDynSetter;

static HBDynGetter g_dynGetters[HB_DYN_MAX];
static int  g_dynGetterCount = 0;
static HBDynSetter g_dynSetters[HB_DYN_MAX];
static int  g_dynSetterCount = 0;

static long long (*HBDynGetterOrigFor(id self))(id, SEL) {
    Class c = object_getClass(self);
    while (c) {
        for (int i = 0; i < g_dynGetterCount; i++) {
            if (g_dynGetters[i].cls == c) return g_dynGetters[i].orig;
        }
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void (*HBDynSetterOrigFor(id self))(id, SEL, long long) {
    Class c = object_getClass(self);
    while (c) {
        for (int i = 0; i < g_dynSetterCount; i++) {
            if (g_dynSetters[i].cls == c) return g_dynSetters[i].orig;
        }
        c = class_getSuperclass(c);
    }
    return NULL;
}

// 幂等保护：动态兜底这一趟可能被重复执行（支付宝的类是懒加载的，要复查）。
// 若不查重，第二次 hook 同一个类时拿到的 "orig" 会是我们自己上一次装进去的 IMP，
// 调用链变成 new_dynApSteps -> new_dynApSteps -> ... 无限递归直接栈溢出。
static BOOL HBDynHasGetter(Class c) {
    for (int i = 0; i < g_dynGetterCount; i++) if (g_dynGetters[i].cls == c) return YES;
    return NO;
}
static BOOL HBDynHasSetter(Class c) {
    for (int i = 0; i < g_dynSetterCount; i++) if (g_dynSetters[i].cls == c) return YES;
    return NO;
}

// 名称白名单：动态兜底只认「名字里带步数语义」的类。
// 单靠方法签名（numberOfSteps 返回 long long）去筛，在支付宝这种体量的 App 里
// 会命中一堆完全无关的类，挂上假步数 getter 后返回 15183 这种值，越界就崩
// （1.0.166 的微信闪退就是这个机理）。加上名称过滤后，
// 抗改名能力基本不变（改名后仍会带 Step/Walk/Sport 等词根），误伤面却小得多。
static BOOL HBDynClassNameLooksLikeSteps(Class c) {
    if (!c) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    // 转小写后匹配，避免大小写差异
    size_t len = strlen(n);
    char lower[256];
    if (len >= sizeof(lower)) len = sizeof(lower) - 1;
    for (size_t i = 0; i < len; i++) {
        lower[i] = (n[i] >= 'A' && n[i] <= 'Z') ? (char)(n[i] + 32) : n[i];
    }
    lower[len] = '\0';
    static const char *keys[] = { "step", "walk", "sport", "pedometer", "health", "motion", NULL };
    for (int i = 0; keys[i]; i++) {
        if (strstr(lower, keys[i]) != NULL) return YES;
    }
    return NO;
}
static long long new_dynApSteps(id self, SEL _cmd) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) {
        static BOOL dynLogged = NO;
        if (!dynLogged) {
            dynLogged = YES;
            HBProbeLog(@"DYN_FAKE: dynamic numberOfSteps -> fake=%ld on class=%@",
                       (long)fake, NSStringFromClass([self class]));
        }
        return (long long)fake;
    }
    long long (*o)(id, SEL) = HBDynGetterOrigFor(self);
    return o ? o(self, _cmd) : 0;
}

static void new_dynSetApSteps(id self, SEL _cmd, long long steps) {
    NSInteger fake = HBReadFakeSteps();
    if (fake > 0) {
        static BOOL dynSetLogged = NO;
        if (!dynSetLogged) {
            dynSetLogged = YES;
            HBProbeLog(@"DYN_SET_FAKE: dynamic setNumberOfSteps: %lld -> %ld on class=%@",
                       steps, (long)fake, NSStringFromClass([self class]));
        }
        steps = (long long)fake;
    }
    void (*o)(id, SEL, long long) = HBDynSetterOrigFor(self);
    if (o) o(self, _cmd, steps);
}

// 系统类一律跳过：支付宝自己的类在 App 包内，系统框架在 /System/Library 下。
// 只 hook App 自己的类，把注入面（以及对支付宝完整性校验的刺激）压到最小。
static BOOL HBIsAppOwnedClass(Class cls) {
    if (!cls) return NO;
    const char *img = class_getImageName(cls);
    if (!img || img[0] == '\0') return NO;
    if (strstr(img, "/System/Library/") != NULL) return NO;
    if (strstr(img, "/usr/lib/")       != NULL) return NO;
    if (strstr(img, "/var/jb/")        != NULL) return NO;
    return YES;
}
// ===== 方案 A+B：支付宝步数类自动探测 + 全量扫描兜底 =====
static void HBLogInjectScanForAlipayClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

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
            fprintf(f, "\n[SCAN] numberOfSteps candidates (%d):\n", numCount);
            for (int i = 0; i < numCount; i++) {
                Method m = class_getInstanceMethod(numStepsCandidates[i], @selector(numberOfSteps));
                const char *enc = m ? method_getTypeEncoding(m) : "?";
                fprintf(f, "  - %s  enc=%s\n", NSStringFromClass(numStepsCandidates[i]).UTF8String, enc);
            }
            fprintf(f, "[SCAN] setNumberOfSteps: candidates (%d):\n", setCount);
            for (int i = 0; i < setCount; i++) {
                Method sm = class_getInstanceMethod(setNumStepsCandidates[i], @selector(setNumberOfSteps:));
                const char *se = sm ? method_getTypeEncoding(sm) : "?";
                fprintf(f, "  - %s  enc=%s\n", NSStringFromClass(setNumStepsCandidates[i]).UTF8String, se);
            }
            fclose(f);
        }
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
        // 把 HKSampleQuery 等假样本 hook 全装上，支付宝累加后截断成 99999。
    const char *prog = getprogname();    // 同步到文件级开关：支付宝 hook 的入口闸门读的是它。
    // 只用局部变量的话，微信进程照样能装支付宝那套动态 hook。    HBRawLog("P2_PROG=%s", prog ? prog : "?");

    // 注入诊断（v1.0.200）：增强版
    // 1) 确认 dylib 是否真的加载进支付宝进程
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
    // 注意：这里原本还会调一次 StepFakerTryHookAlipay()。
        // 但 1.0.166 加了「动态扫描 + 按签名 hook」之后，同样的调用会去扫描并 hook
            StepFakerTryHookAlipay();
    HBRawLog("P9_DONE_WECHAT");
}
