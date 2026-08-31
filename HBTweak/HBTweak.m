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
// 跨进程传值（关键改进 v76）：
//   v75 只用 CFPreferences（com.apple.mobile.healthboost）。在 roothide 下，
//   App（装在 /var/jb/Applications）和微信（装在 /var/containers）对 CFPreferences
//   的落盘路径可能被不同重定向，导致微信读不到 App 写的值。
//   所以 v76 改为「文件优先」：App 把步数写到
//       /var/mobile/Media/HealthBoost/hb_steps.txt
//   这是真实共享路径，双方都看得到，最稳。CFPreferences 作为兜底保留。
//
// 致命缺陷修复（v76 核心）：
//   v75 在 dylib 的 @constructor 里直接 NSClassFromString(@"WCDeviceStepObject")
//   并 hook。但 @constructor 执行时微信自己的私有步数框架可能还没加载，
//   类不存在 -> hook 被静默跳过 -> tweak 完全不生效（用户看到的就是「微信没用」）。
//   v76 改为：先在 constructor 尝试 hook；若类还没加载，则在主线程 dispatch_after
//   里重试最多 5 次（每次隔 2 秒），直到类可用再 hook。
//
// 可诊断性（v76 新增）：
//   用户无法访问系统日志/Console，所以 tweak 把关键事件写进
//       /var/mobile/Media/HealthBoost/tweak_log.txt
//   用户点 HealthBoost App 的「查看日志」即可看到 tweak 是否加载、类是否找到、
//   步数 getter 被调用时返回的是假值还是原值。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// ---- 路径定义 ----
#define HB_STEPS_FILE     @"/var/mobile/Media/HealthBoost/hb_steps.txt"
#define HB_TWEAK_LOG_PATH @"/var/mobile/Media/HealthBoost/tweak_log.txt"
#define HB_PREF_DOMAIN    CFSTR("com.apple.mobile.healthboost")
#define HB_PREF_KEY       CFSTR("steps")
#define HB_TWEAK_MAX_LINES 140

// MARK: - 诊断日志（用户可读，App「查看日志」会显示）

static void HBTweakLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSString *path = HB_TWEAK_LOG_PATH;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    if (old.length > 0) {
        [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];
        while (lines.count > 0 && [lines.lastObject length] == 0) [lines removeLastObject];
    }
    [lines addObject:line];
    while (lines.count > HB_TWEAK_MAX_LINES) [lines removeObjectAtIndex:0];

    NSString *out = [lines componentsJoinedByString:@"\n"];
    if (lines.count > 0) out = [out stringByAppendingString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// MARK: - 读取 App 设定的步数

// 1) 文件优先（roothide 下最稳的跨进程通道）
// 2) CFPreferences 兜底
// 返回 -1 表示「未配置 / 配置为 0」-> 不劫持，走原值
static long HBConfiguredSteps(void) {
    // 1) 文件
    NSString *c = [NSString stringWithContentsOfFile:HB_STEPS_FILE
                                           encoding:NSUTF8StringEncoding error:nil];
    if (c.length > 0) {
        NSArray *parts = [c componentsSeparatedByString:@"\n"];
        NSString *first = [parts.firstObject stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (first.length > 0) {
            long v = (long)[first longLongValue];
            if (v > 0) return v;
        }
    }
    // 2) CFPreferences 兜底
    CFPropertyListRef v = CFPreferencesCopyValue(HB_PREF_KEY, HB_PREF_DOMAIN,
                                                 kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (v) {
        long steps = -1;
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &steps);
        } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
            steps = (long)[(__bridge NSString *)v longLongValue];
        }
        CFRelease(v);
        if (steps > 0) return steps;
    }
    return -1;
}

// MARK: - 通用替换（带缺失保护）

static void HBReplace(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        HBTweakLog(@"WARN: %s 在 %s 上不存在，跳过 hook",
                   sel_getName(sel), class_getName(cls));
        return;
    }
    IMP orig = method_getImplementation(m);
    if (origImp) *origImp = orig;
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
}

// MARK: - 步数 getter 统一实现

typedef NSInteger (*HBStepGetter)(id, SEL);
static HBStepGetter gOrig_stepCount   = NULL;
static HBStepGetter gOrig_hkStepCount = NULL;
static HBStepGetter gOrig_m7StepCount = NULL;

static int  gCallCount       = 0;
static BOOL gLoggedFake       = NO;
static BOOL gLoggedOriginal   = NO;

static NSInteger HBReturnSteps(HBStepGetter orig, id self, SEL _cmd, const char *name) {
    long s = HBConfiguredSteps();
    gCallCount++;
    if (s >= 0) {
        if (!gLoggedFake) {
            gLoggedFake = YES;
            HBTweakLog(@"GETTER %s -> 返回假步数 %ld (第%d次调用)", name, s, gCallCount);
        } else if (gCallCount % 500 == 0) {
            HBTweakLog(@"GETTER %s -> 返回假步数 %ld (第%d次调用)", name, s, gCallCount);
        }
        return (NSInteger)s;
    }
    if (!gLoggedOriginal) {
        gLoggedOriginal = YES;
        HBTweakLog(@"GETTER %s -> 返回原值（未配置假步数）", name);
    }
    return orig ? orig(self, _cmd) : 0;
}

static NSInteger HB_stepCount(id self, SEL _cmd) {
    return HBReturnSteps(gOrig_stepCount, self, _cmd, "stepCount");
}
static NSInteger HB_hkStepCount(id self, SEL _cmd) {
    return HBReturnSteps(gOrig_hkStepCount, self, _cmd, "hkStepCount");
}
static NSInteger HB_m7StepCount(id self, SEL _cmd) {
    return HBReturnSteps(gOrig_m7StepCount, self, _cmd, "m7StepCount");
}

// MARK: - 安装 hook（可重试，解决类延迟加载问题）

static BOOL HBInstallHooksOnce(void) {
    static BOOL done = NO;
    if (done) return YES;

    Class wcCls = NSClassFromString(@"WCDeviceStepObject");
    if (!wcCls) return NO;   // 类还没加载，等下次重试

    HBReplace(wcCls, @selector(stepCount),   (IMP)HB_stepCount,   (IMP *)&gOrig_stepCount);
    HBReplace(wcCls, @selector(hkStepCount), (IMP)HB_hkStepCount, (IMP *)&gOrig_hkStepCount);
    HBReplace(wcCls, @selector(m7StepCount), (IMP)HB_m7StepCount, (IMP *)&gOrig_m7StepCount);

    Class apCls = NSClassFromString(@"APStepInfo");
    if (apCls) {
        HBReplace(apCls, @selector(numberOfSteps), (IMP)HB_stepCount, NULL);
    }

    done = YES;
    long cur = HBConfiguredSteps();
    HBTweakLog(@"HOOK 完成: WCDeviceStepObject=YES, APStepInfo=%@, 当前配置步数=%ld",
               apCls ? @"YES" : @"NO", cur);
    return YES;
}

// MARK: - 构造函数（dylib 被注入时自动执行）

__attribute__((constructor))
static void HBHealthBoostTweakInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        HBTweakLog(@"tweak 已加载, 进程=%@, pid=%d", bid, getpid());

        // 【v77 修复】去掉自杀式 bundle 强校验。
        // 之前写 if (![bid isEqualToString:@"com.tencent.xin"]) return;
        // 但微信步数进程的真实 bundle 是 UGGD（UCStep 的 filter 即为 UGGD），
        // 注入进 UGGD 后 bid=UGGD ≠ com.tencent.xin 被直接 return，导致 hook 从不执行。
        // 现在由 plist 的 Filter 控制注入目标，这里不再拦截，任何被注入的进程都尝试 hook。

        // 立即尝试一次
        if (HBInstallHooksOnce()) {
            HBTweakLog(@"首次尝试即 hook 完成 (进程=%@)", bid);
            return;
        }

        // 类还没加载：主线程延迟重试（类通常在 App 启动后几秒内可用）
        HBTweakLog(@"WCDeviceStepObject 尚未加载，安排主线程重试 (进程=%@)", bid);
        for (NSInteger i = 1; i <= 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (HBInstallHooksOnce()) {
                    HBTweakLog(@"hook 在第 %ld 次重试时安装成功 (进程=%@)", (long)i, bid);
                } else if (i == 8) {
                    HBTweakLog(@"错误: 8 次重试后仍找不到 WCDeviceStepObject (进程=%@)，hook 失败", bid);
                }
            });
        }
    }
}
