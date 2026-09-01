// HealthBoost Tweak —— 注入微信，劫持步数读取接口
//
// ============================ 背景与踩过的坑 ============================
// 1) 写 HealthKit 只能让「健康」App 显示步数，微信运动不同步。
//    逆向 UCStep 后确认：微信运动优先读 M7 协处理器步数（WCDeviceStepObject.m7StepCount），
//    而不是 HealthKit。所以必须在微信进程内 hook，这是与 HealthKit 完全独立的第二条链路。
//
// 2) 【v78 关键修复】沙盒问题 —— 这是 v75~v77 一直「没用」的真正原因：
//    微信是 App Store 应用，运行在沙盒里。前几版把步数写在
//        /var/mobile/Media/HealthBoost/hb_steps.txt
//    并指望微信里的 tweak 去读它 —— 但微信的沙盒根本不允许读取这个路径！
//    结果 HBConfiguredSteps() 恒返回 -1，hook 直接返回原值，等于没 hook。
//    同理，tweak 的日志也写不进 /var/mobile/Media/，所以 tweak_log.txt 永远不存在
//    （这曾被误判为「tweak 没注入」，实际是写日志被沙盒拒绝）。
//
//    竞品 UCStep 用的是 CFPreferences 域 com.apple.mobile.ifucstepcommon，
//    带 com.apple. 前缀 = 系统域，由 cfprefsd 中介，可以跨沙盒读取。这就是正解。
//
//    v78 因此改为「多通道 + 沙盒优先」：
//      - 读值：CFPreferences(主) -> 自身容器 Documents/hb_steps.txt -> /var/mobile/Media(兜底)
//      - 日志：自身容器 Documents/hb_tweak_log.txt(主，沙盒内必定可写) -> /var/mobile/Media(兜底)
//    HealthBoost App 带 no-sandbox 权限，会主动把 hb_steps.txt 写进微信自己的容器，
//    并扫描所有容器把 tweak 日志读回来显示。
//
// 3) hook 目标对齐 UCStep（其 dylib 字符串实证）：
//      WCDeviceStepObject : stepCount / hkStepCount / m7StepCount / setStepCount:
//      APStepInfo         : numberOfSteps
//      APStepCountServiceImpl : numberOfSteps / monitorStepCountNotChangedForApp:numberOfSteps:
//
// 4) 延迟 hook：dylib 的 @constructor 早于微信私有框架加载，
//    直接 NSClassFromString 会拿到 nil。所以先试一次，失败则主线程定时重试。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

// ---- 路径与域 ----
#define HB_STEPS_FILE      @"/var/mobile/Media/HealthBoost/hb_steps.txt"
#define HB_STEPS_NAME      @"hb_steps.txt"
#define HB_TWEAKLOG_NAME   @"hb_tweak_log.txt"
#define HB_MEDIA_TWEAKLOG  @"/var/mobile/Media/HealthBoost/tweak_log.txt"
#define HB_PREF_DOMAIN     CFSTR("com.apple.mobile.healthboost")
#define HB_PREF_KEY        CFSTR("steps")
#define HB_LOG_MAX_LINES   160

// MARK: - 沙盒内可写目录（tweak 的日志落点）

// 返回进程自己容器里的 Documents 路径 —— 沙盒内必定可写。
// HealthBoost App 是无沙盒的，会遍历 /var/mobile/Containers/Data/Application/* 找到这个文件。
static NSString *HBOwnDocuments(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                            NSUserDomainMask, YES);
        NSString *doc = dirs.firstObject;
        if (doc.length == 0) doc = NSHomeDirectory();
        cached = doc ?: @"";
    });
    return cached.length ? cached : nil;
}

static NSString *HBOwnLogPath(void) {
    NSString *doc = HBOwnDocuments();
    return doc ? [doc stringByAppendingPathComponent:HB_TWEAKLOG_NAME] : nil;
}

static NSString *HBOwnStepsPath(void) {
    NSString *doc = HBOwnDocuments();
    return doc ? [doc stringByAppendingPathComponent:HB_STEPS_NAME] : nil;
}

// MARK: - 诊断日志（双落点：自身容器优先，Media 兜底）

static BOOL HBTweakLogTo(NSString *path, NSString *line) {
    if (!path) return NO;
    BOOL ok = NO;
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (dir.length && ![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *old = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *lines = [NSMutableArray array];
        if (old.length > 0) {
            [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];
            while (lines.count > 0 && [lines.lastObject length] == 0) [lines removeLastObject];
        }
        [lines addObject:line];
        while (lines.count > HB_LOG_MAX_LINES) [lines removeObjectAtIndex:0];
        NSString *out = [lines componentsJoinedByString:@"\n"];
        if (lines.count > 0) out = [out stringByAppendingString:@"\n"];
        ok = [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return ok;
}

static void HBTweakLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg];

    // 逐级兜底：
    //   1) 自身容器 Documents —— 普通 App 沙盒内必定可写（微信就是这种情况）
    //   2) /var/mobile/Documents —— 没有数据容器的守护进程（如 UGGD）落在这里
    //   3) 共享 Media 目录 —— 仅无沙盒进程可写（SpringBoard 等）
    BOOL ok = HBTweakLogTo(HBOwnLogPath(), line);
    if (!ok) {
        NSString *alt = @"/var/mobile/Documents/hb_tweak_log.txt";
        if (![alt isEqualToString:(HBOwnLogPath() ?: @"")]) {
            ok = HBTweakLogTo(alt, line);
        }
    }
    HBTweakLogTo(HB_MEDIA_TWEAKLOG, line);
}

// MARK: - 多通道读取配置步数

static long HBReadFileSteps(NSString *path) {
    if (!path) return -1;
    NSString *c = [NSString stringWithContentsOfFile:path
                                           encoding:NSUTF8StringEncoding error:nil];
    if (c.length == 0) return -1;
    NSString *first = [[c componentsSeparatedByString:@"\n"].firstObject
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (first.length == 0) return -1;
    long v = (long)[first longLongValue];
    return v > 0 ? v : -1;
}

static long HBReadPrefSteps(void) {
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
    return steps > 0 ? steps : -1;
}

// 返回 -1 表示未配置（此时 hook 应返回原值）
// channel 输出命中的通道名，便于诊断
static long HBConfiguredSteps(const char **channel) {
    long v;
    // 1) CFPreferences —— 跨沙盒正解（UCStep 同款手法）
    if ((v = HBReadPrefSteps()) > 0) { if (channel) *channel = "CFPreferences"; return v; }
    // 2) 自身容器内的文件 —— HealthBoost App 会写进来
    if ((v = HBReadFileSteps(HBOwnStepsPath())) > 0) { if (channel) *channel = "ownContainer"; return v; }
    // 3) /var/mobile/Documents —— 给没有数据容器的守护进程（UGGD）用
    if ((v = HBReadFileSteps(@"/var/mobile/Documents/hb_steps.txt")) > 0) {
        if (channel) *channel = "varMobileDocuments"; return v;
    }
    // 4) 共享 Media 目录（仅无沙盒进程可读）
    if ((v = HBReadFileSteps(HB_STEPS_FILE)) > 0) { if (channel) *channel = "media"; return v; }
    if (channel) *channel = "NONE";
    return -1;
}

// 带 2 秒缓存：getter 可能被调用极频繁，不能每次都读文件
static long HBCachedSteps(void) {
    static long cached = -2;
    static double lastRead = 0;
    double now = CFAbsoluteTimeGetCurrent();
    if (cached == -2 || now - lastRead > 2.0) {
        const char *ch = NULL;
        cached = HBConfiguredSteps(&ch);
        lastRead = now;
        static BOOL loggedOnce = NO;
        static const char *lastCh = NULL;
        if (!loggedOnce || lastCh != ch) {
            loggedOnce = YES;
            lastCh = ch;
            HBTweakLog(@"读取步数: 值=%ld 通道=%s (容器=%@)", cached, ch, HBOwnDocuments() ?: @"(nil)");
        }
    }
    return cached;
}

// MARK: - Hook 注册表（类型感知）

#define HB_MAX_HOOKS 24

typedef NSInteger (*HBIntGetterIMP)(id, SEL);
typedef id        (*HBObjGetterIMP)(id, SEL);
typedef void      (*HBIntSetterIMP)(id, SEL, NSInteger);
typedef void      (*HBObjSetterIMP)(id, SEL, id);

typedef struct {
    Class cls;
    SEL   sel;
    IMP   orig;
    char  label[64];
    int   kind;   // 0=整数getter 1=对象getter 2=整数setter 3=对象setter
} HBHookRec;

static HBHookRec gHooks[HB_MAX_HOOKS];
static int       gHookCount = 0;
static int       gGetterCallCount = 0;
static int       gGetterLogBudget = 12;   // getter 日志条数上限，避免刷爆日志

static HBHookRec *HBFindRec(id self, SEL _cmd) {
    for (int i = 0; i < gHookCount; i++) {
        if (!sel_isEqual(gHooks[i].sel, _cmd)) continue;
        if (!gHooks[i].cls || [self isKindOfClass:gHooks[i].cls]) return &gHooks[i];
    }
    return NULL;
}

// 统一的「取假步数」判定 + 节流日志
static NSInteger HBFakeOrOriginal(HBHookRec *r, const char *label) {
    gGetterCallCount++;
    long s = HBCachedSteps();
    if (s >= 0) {
        if (gGetterLogBudget > 0 && (gGetterCallCount <= 3 || gGetterCallCount % 5000 == 0)) {
            gGetterLogBudget--;
            HBTweakLog(@"GETTER %s -> 返回假步数 %ld (第%d次调用)", label, s, gGetterCallCount);
        }
        return (NSInteger)s;
    }
    if (gGetterLogBudget > 0 && gGetterCallCount <= 3) {
        gGetterLogBudget--;
        HBTweakLog(@"GETTER %s -> 返回原值（未读到配置步数，通道全部失败）", label);
    }
    return -1;  // 表示「用原值」
}

static NSInteger HB_intGetter(id self, SEL _cmd) {
    HBHookRec *r = HBFindRec(self, _cmd);
    NSInteger fake = HBFakeOrOriginal(r, r ? r->label : "?");
    if (fake >= 0) return fake;
    IMP orig = r ? r->orig : NULL;
    return orig ? ((HBIntGetterIMP)orig)(self, _cmd) : 0;
}

static id HB_objGetter(id self, SEL _cmd) {
    HBHookRec *r = HBFindRec(self, _cmd);
    NSInteger fake = HBFakeOrOriginal(r, r ? r->label : "?");
    if (fake >= 0) return @(fake);
    IMP orig = r ? r->orig : NULL;
    return orig ? ((HBObjGetterIMP)orig)(self, _cmd) : nil;
}

static void HB_intSetter(id self, SEL _cmd, NSInteger v) {
    HBHookRec *r = HBFindRec(self, _cmd);
    long s = HBCachedSteps();
    NSInteger toSet = (s >= 0) ? (NSInteger)s : v;
    if (s >= 0 && gGetterLogBudget > 0) {
        gGetterLogBudget--;
        HBTweakLog(@"SETTER %s -> 原值 %ld 被改写为假步数 %ld", r ? r->label : "?", (long)v, s);
    }
    IMP orig = r ? r->orig : NULL;
    if (orig) ((HBIntSetterIMP)orig)(self, _cmd, toSet);
}

static void HB_objSetter(id self, SEL _cmd, id v) {
    HBHookRec *r = HBFindRec(self, _cmd);
    long s = HBCachedSteps();
    id toSet = v;
    if (s >= 0) {
        toSet = @(s);
        if (gGetterLogBudget > 0) {
            gGetterLogBudget--;
            HBTweakLog(@"SETTER %s -> 原值 %@ 被改写为假步数 %ld", r ? r->label : "?", v, s);
        }
    }
    IMP orig = r ? r->orig : NULL;
    if (orig) ((HBObjSetterIMP)orig)(self, _cmd, toSet);
}

// 安装一个 hook，按方法签名自动选择 IMP 形态（避免返回值/参数类型不匹配导致崩溃）
static void HBInstallOne(Class cls, SEL sel, const char *label, int isSetter) {
    if (!cls || !sel || gHookCount >= HB_MAX_HOOKS) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        HBTweakLog(@"WARN: -[%s %s] 不存在，跳过", class_getName(cls), sel_getName(sel));
        return;
    }

    char ret[64] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    char arg[64] = {0};
    if (isSetter) method_getArgumentType(m, 2, arg, sizeof(arg));

    int kind = -1;
    IMP newImp = NULL;
    if (!isSetter) {
        if (ret[0] == '@' || ret[0] == '#')        { kind = 1; newImp = (IMP)HB_objGetter; }
        else if (strchr("cislqCISLQB", ret[0]))    { kind = 0; newImp = (IMP)HB_intGetter; }
    } else {
        if (arg[0] == '@' || arg[0] == '#')        { kind = 3; newImp = (IMP)HB_objSetter; }
        else if (strchr("cislqCISLQB", arg[0]))    { kind = 2; newImp = (IMP)HB_intSetter; }
    }

    if (kind < 0) {
        HBTweakLog(@"WARN: -[%s %s] 签名不支持 (ret=%s arg=%s)，跳过",
                   class_getName(cls), sel_getName(sel), ret, arg);
        return;
    }

    IMP orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));

    HBHookRec *rec = &gHooks[gHookCount++];
    rec->cls = cls;
    rec->sel = sel;
    rec->orig = orig;
    rec->kind = kind;
    strncpy(rec->label, label, sizeof(rec->label) - 1);
    HBTweakLog(@"HOOK OK: -[%s %s] kind=%d", class_getName(cls), sel_getName(sel), kind);
}

// MARK: - 安装全部 hook（可重试）

static BOOL HBInstallHooksOnce(void) {
    static BOOL done = NO;
    if (done) return YES;

    Class wcCls = NSClassFromString(@"WCDeviceStepObject");
    if (!wcCls) return NO;

    HBInstallOne(wcCls, @selector(stepCount),    "WCDeviceStepObject.stepCount",    0);
    HBInstallOne(wcCls, @selector(hkStepCount),  "WCDeviceStepObject.hkStepCount",  0);
    HBInstallOne(wcCls, @selector(m7StepCount),  "WCDeviceStepObject.m7StepCount",  0);
    HBInstallOne(wcCls, @selector(setStepCount:),"WCDeviceStepObject.setStepCount:", 1);

    Class apCls = NSClassFromString(@"APStepInfo");
    if (apCls) HBInstallOne(apCls, @selector(numberOfSteps), "APStepInfo.numberOfSteps", 0);

    Class svcCls = NSClassFromString(@"APStepCountServiceImpl");
    if (svcCls) {
        HBInstallOne(svcCls, @selector(numberOfSteps), "APStepCountServiceImpl.numberOfSteps", 0);
    }

    done = YES;

    const char *ch = NULL;
    long cur = HBConfiguredSteps(&ch);
    HBTweakLog(@"HOOK 完成: WCDeviceStepObject=YES APStepInfo=%@ APStepCountServiceImpl=%@ 共%d个 "
               @"| 当前步数=%ld 通道=%s",
               apCls ? @"YES" : @"NO", svcCls ? @"YES" : @"NO", gHookCount, cur, ch);
    return YES;
}

// MARK: - 注入探针（裸 POSIX 直写，独立于任何 ObjC 初始化，确保只要 dylib 被加载就必然落盘）

// 只要 tweak 被加载进任意进程，立刻用裸 libc 写两个标记文件：
//   1) /var/mobile/Media/HealthBoost/injected/<bid>.txt   —— 无沙盒进程（SpringBoard / HealthBoost App）可写
//   2) 自身容器 Documents/hb_injected_<bid>.txt            —— 沙盒进程（微信）可写
// 这样 App 端「注入自检」只需扫这两个位置，就能 100% 确定「dylib 到底有没有被加载」，
// 不再依赖后面的 ObjC 日志逻辑（那套在某些崩溃场景下可能根本跑不到）。
static void HBWriteInjectionMarker(void) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
    char pidstr[16];
    snprintf(pidstr, sizeof(pidstr), "%d", (int)getpid());

    // bundle id（尽量取，失败则用 unknown）
    const char *bidc = "unknown";
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length) bidc = [bid UTF8String];
    }

    // 1) Media 路径
    const char *mediaDir = "/var/mobile/Media/HealthBoost/injected";
    mkdir(mediaDir, 0755);
    char mediaPath[768];
    snprintf(mediaPath, sizeof(mediaPath), "%s/%s.txt", mediaDir, bidc);
    FILE *f = fopen(mediaPath, "w");
    if (f) { fprintf(f, "injected_at=%s pid=%s\n", ts, pidstr); fclose(f); }

    // 2) 自身容器 Documents 路径
    @autoreleasepool {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = docs.firstObject;
        if (doc.length) {
            NSString *p = [doc stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"hb_injected_%s.txt", bidc]];
            FILE *f2 = fopen([p UTF8String], "w");
            if (f2) { fprintf(f2, "injected_at=%s pid=%s\n", ts, pidstr); fclose(f2); }
        }
    }
}

// MARK: - 构造函数

__attribute__((constructor))
static void HBHealthBoostTweakInit(void) {
    // 第一件事：裸 POSIX 写注入标记（证明 dylib 被加载），不依赖后续任何 ObjC 逻辑
    HBWriteInjectionMarker();

    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)";
        NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"(null)";
        HBTweakLog(@"=== tweak 已加载 === 进程=%@ bid=%@ pid=%d 容器=%@",
                   exe, bid, getpid(), HBOwnDocuments() ?: @"(nil)");

        // 立刻探测一次各通道可读性，写入日志（沙盒问题一眼可见）
        {
            long p = HBReadPrefSteps();
            long o = HBReadFileSteps(HBOwnStepsPath());
            long m = HBReadFileSteps(HB_STEPS_FILE);
            HBTweakLog(@"通道探测: CFPreferences=%ld 自身容器=%ld 共享Media=%ld", p, o, m);
        }

        if (HBInstallHooksOnce()) {
            HBTweakLog(@"首次尝试即完成 hook");
        } else {
            HBTweakLog(@"WCDeviceStepObject 尚未加载，安排主线程重试");
        }

        // 延迟重试：微信私有框架通常启动后几秒内才加载
        for (NSInteger i = 1; i <= 10; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (HBInstallHooksOnce()) {
                    if (i <= 3 || i == 10) HBTweakLog(@"hook 在第 %ld 次重试时完成", (long)i);
                } else if (i == 10) {
                    HBTweakLog(@"错误: 10 次重试后仍找不到 WCDeviceStepObject，hook 失败");
                }
            });
        }

        // 心跳：每 60 秒记一次，证明 tweak 还活着（最多 10 条）
        for (NSInteger i = 1; i <= 10; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 60 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                const char *ch = NULL;
                long v = HBConfiguredSteps(&ch);
                HBTweakLog(@"心跳#%ld: 步数=%ld 通道=%s 累计getter调用=%d",
                           (long)i, v, ch, gGetterCallCount);
            });
        }
    }
}
