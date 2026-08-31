// HealthBoost - iOS App that writes steps / distance / flights to Apple Health as device source
// 使用 com.apple.private.healthkit.source_override + authorization_bypass 私有权限
// 让写出的 step count 来源伪装成 iPhone 设备源，从而被微信运动等应用读取
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// 前向声明：HBDumpEntitlements 定义在 HBLog 之前，需先声明否则会触发隐式声明错误
static void HBLog(NSString *fmt, ...);

static NSString * const HBSettingsKey = @"com.sykes.healthboost.settings";

// MARK: - Logging helper
// 日志同时写到两个位置：
//   1) /var/mobile/Media/HealthBoost/hb_log.txt  —— Files App「我的 iPhone」里能直接看到
//   2) App 沙盒 Documents/hb_log.txt              —— 保底，App 内「查看日志」能读
// App 带 com.apple.private.security.no-sandbox，可写沙盒外路径。

// 追加一行到指定路径，并自动裁剪为滚动日志（最多保留 HB_MAX_LOG_LINES 行）
// 防止日志无限增长导致 UIPasteboard 复制失败 / 弹窗截断。
static const NSInteger HB_MAX_LOG_LINES = 200;

static void HBAppendLine(NSString *path, NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 读取旧日志
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    if (old.length > 0) {
        [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];
        // 去掉末尾可能存在的空行
        while (lines.count > 0 && [lines.lastObject length] == 0) {
            [lines removeLastObject];
        }
    }

    // 追加新行
    [lines addObject:line];

    // 滚动裁剪：保留最后 HB_MAX_LOG_LINES 行
    while (lines.count > HB_MAX_LOG_LINES) {
        [lines removeObjectAtIndex:0];
    }

    // 写回
    NSString *out = [lines componentsJoinedByString:@"\n"];
    if (lines.count > 0) out = [out stringByAppendingString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 外部共享日志路径（Files App 可见）
static NSString *HBSharedLogPath(void) {
    return @"/var/mobile/Media/HealthBoost/hb_log.txt";
}

// API 探测输出路径：把 HealthKit 相关类的全部方法（含私有）导出到这里，
// 用于定位真正能改写 sample 来源的私有初始化器 / 保存入口。
static NSString *HBAPIDumpPath(void) {
    return @"/var/mobile/Media/HealthBoost/api_dump.txt";
}

// 枚举某个类的所有实例方法（含私有），追加到 out
static void HBDumpMethods(NSMutableString *out, Class cls, NSString *clsName, NSArray *keywords) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (name == NULL) continue;
        NSString *sn = [NSString stringWithUTF8String:name];
        // 若给了关键字，只输出命中的；否则全输出
        BOOL hit = (keywords == nil);
        for (NSString *kw in keywords) {
            if ([sn rangeOfString:kw options:NSCaseInsensitiveSearch].length > 0) { hit = YES; break; }
        }
        if (hit) {
            // 附带参数个数与方法签名，便于安全构造 NSInvocation
            unsigned int nargs = method_getNumberOfArguments(methods[i]);
            const char *types = method_getTypeEncoding(methods[i]);
            [out appendFormat:@"%@ : %@   [args=%u types=%s]\n",
             clsName, sn, nargs, types ? types : ""];
        }
    }
    free(methods);
}

// 把步数写到「供微信 tweak 读取」的通道。
// 双通道（v76 起）：
//   1) 文件 /var/mobile/Media/HealthBoost/hb_steps.txt —— 真实共享路径，roothide 下最稳，
//      微信进程里的 tweak 直接读这个文件。这是主通道。
//   2) CFPreferences com.apple.mobile.healthboost —— 兜底。
// 这一步与写 HealthKit 是两条独立链路：HealthKit 管「健康」App，这里管「微信运动」。
static void HBWriteStepsFile(long steps) {
    NSString *dir = @"/var/mobile/Media/HealthBoost";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *path = [dir stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n", steps];
    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    HBLog(@"[HealthBoost] 已写入步数文件 %ld (file=%d) @ %@", steps, ok, path);
}

static void HBWriteStepsPreference(long steps) {
    // 主通道：文件
    HBWriteStepsFile(steps);
    // 兜底：CFPreferences
    CFPreferencesSetValue(CFSTR("steps"),
                          (__bridge CFNumberRef)@(steps),
                          CFSTR("com.apple.mobile.healthboost"),
                          kCFPreferencesAnyUser,
                          kCFPreferencesAnyHost);
    BOOL ok = CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"),
                                       kCFPreferencesAnyUser,
                                       kCFPreferencesAnyHost);
    HBLog(@"[HealthBoost] 已写入步数偏好 %ld (sync=%d)，供微信 tweak 读取", steps, ok);
}

// 读取自身 entitlements 的实际生效值
// 目的：确认 ldid 签的 com.apple.private.healthkit.source_override 到底有没有被系统认可。
// 注意：SecTask 系列在 iOS SDK 中没有公开头文件（属 macOS 私有 API），
// 这里用 dlsym 运行时查找，找不到就跳过，避免编译/链接失败或运行时崩溃。
static void HBDumpEntitlements(void) {
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    if (!sec) {
        HBLog(@"[HealthBoost] ENT: Security.framework 加载失败");
        return;
    }

    typedef struct __SecTask *HBSecTaskRef;
    HBSecTaskRef (*hbSecTaskCreateFromSelf)(CFAllocatorRef) =
        (HBSecTaskRef (*)(CFAllocatorRef))dlsym(sec, "SecTaskCreateFromSelf");
    CFTypeRef (*hbSecTaskCopyValueForEntitlement)(HBSecTaskRef, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(HBSecTaskRef, CFStringRef, CFErrorRef *))dlsym(sec, "SecTaskCopyValueForEntitlement");

    if (!hbSecTaskCreateFromSelf || !hbSecTaskCopyValueForEntitlement) {
        HBLog(@"[HealthBoost] ENT: SecTask 符号不可用（iOS 未导出），跳过检查");
        return;
    }

    HBSecTaskRef task = hbSecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        HBLog(@"[HealthBoost] ENT: SecTaskCreateFromSelf 返回 NULL");
        return;
    }

    NSArray *keys = @[
        @"com.apple.private.healthkit.source_override",
        @"com.apple.private.healthkit.authorization_bypass",
        @"com.apple.private.healthkit.write_authorization_override",
        @"com.apple.private.security.storage.Health",
        @"com.apple.developer.healthkit",
        @"application-identifier",
    ];
    for (NSString *k in keys) {
        CFTypeRef v = hbSecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)k, NULL);
        if (v) {
            HBLog(@"[HealthBoost] ENT %@ = %@", k, (__bridge id)v);
            CFRelease(v);
        } else {
            HBLog(@"[HealthBoost] ENT %@ = (nil 未生效)", k);
        }
    }
    CFRelease(task);
}

// 导出 API 清单到共享目录（不受日志行数限制）
static void HBDumpHealthKitAPIs(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== HealthKit 私有 API 探测 ===\n\n"];

    // 只关心与「来源 / 初始化 / 保存」相关的方法，避免文件过大
    NSArray *kws = @[@"init", @"source", @"save", @"revision", @"device", @"insert", @"add", @"origin"];

    [out appendString:@"--- HKQuantitySample ---\n"];
    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", kws);

    [out appendString:@"\n--- HKSample ---\n"];
    HBDumpMethods(out, [HKSample class], @"HKSample", kws);

    [out appendString:@"\n--- HKSourceRevision ---\n"];
    HBDumpMethods(out, [HKSourceRevision class], @"HKSourceRevision", nil);

    [out appendString:@"\n--- HKSource ---\n"];
    HBDumpMethods(out, [HKSource class], @"HKSource", nil);

    [out appendString:@"\n--- HKHealthStore (save/delete 相关) ---\n"];
    HBDumpMethods(out, [HKHealthStore class], @"HKHealthStore", @[@"save", @"delete", @"insert", @"add"]);

    [out appendString:@"\n--- HKQuantitySample 全部方法 ---\n"];
    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", nil);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [HBAPIDumpPath() stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [out writeToFile:HBAPIDumpPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 沙盒内日志路径（保底）
static NSString *HBSandboxLogPath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [doc stringByAppendingPathComponent:@"hb_log.txt"];
}

static void HBLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%@", msg);

    NSDateFormatter *fmtDate = [[NSDateFormatter alloc] init];
    fmtDate.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmtDate stringFromDate:[NSDate date]], msg];

    HBAppendLine(HBSharedLogPath(), line);
    HBAppendLine(HBSandboxLogPath(), line);
}

// MARK: - Helper: create HKQuantitySample with device source via KVC

static HKQuantitySample *HBMakeDeviceSample(HKQuantityType *type,
                                           HKQuantity *quantity,
                                           NSDate *start,
                                           NSDate *end,
                                           HKSourceRevision *deviceSourceRev) {
    HKDevice *device = [HKDevice localDevice];
    HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type
                                                              quantity:quantity
                                                           startDate:start
                                                             endDate:end
                                                               device:device
                                                           metadata:nil];
    if (!sample) return nil;
    // KVC 注入私有 ivar _sourceRevision，让 healthd 接受设备源
    if (deviceSourceRev) {
        @try {
            [sample setValue:[deviceSourceRev copy] forKey:@"_sourceRevision"];
        } @catch (NSException *e) {
            (void)e;
            // 回退：不注入 sourceRevision
        }
    }
    return sample;
}

// MARK: - Main View Controller

@interface HBMainViewController : UIViewController <UITextFieldDelegate>
@property (strong, nonatomic) UISwitch *enableSwitch;
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UITextField *stepsField;
@property (strong, nonatomic) UITextField *flightsField;
@property (strong, nonatomic) UISlider *ratioSlider;
@property (strong, nonatomic) UILabel *ratioLabel;
@property (strong, nonatomic) UILabel *distanceLabel;
@property (strong, nonatomic) UIButton *applyButton;
@property (strong, nonatomic) HKHealthStore *healthStore;
@property (assign, nonatomic) BOOL busy;
@end

@implementation HBMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    CGFloat w = self.view.bounds.size.width;
    CGFloat margin = 24;
    CGFloat y = 70;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 40)];
    title.text = @"HealthBoost";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = [UIColor labelColor];
    [self.view addSubview:title];
    y += 54;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 36)];
    self.statusLabel.text = @"配置加载中...";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];
    y += 46;

    self.enableSwitch = [[UISwitch alloc] init];
    self.enableSwitch.frame = CGRectMake(w - margin - 51, y, 51, 31);
    [self.enableSwitch addTarget:self action:@selector(enableChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.enableSwitch];

    UILabel *enableLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y + 2, w - margin*2 - 60, 28)];
    enableLabel.text = @"启用健康数据修改";
    enableLabel.font = [UIFont systemFontOfSize:17];
    enableLabel.textColor = [UIColor labelColor];
    [self.view addSubview:enableLabel];
    y += 54;

    y = [self addSectionTitle:@"步数" y:y];
    UIView *stepsRow = [[UIView alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 44)];
    stepsRow.backgroundColor = [UIColor secondarySystemBackgroundColor];
    stepsRow.layer.cornerRadius = 10;

    UIButton *stepMinus = [self roundedButton:@"-100" color:[UIColor systemGrayColor]];
    stepMinus.frame = CGRectMake(8, 6, 64, 32);
    [stepMinus addTarget:self action:@selector(stepMinusTapped:) forControlEvents:UIControlEventTouchUpInside];
    [stepsRow addSubview:stepMinus];

    self.stepsField = [[UITextField alloc] initWithFrame:CGRectMake(80, 6, stepsRow.bounds.size.width - 160, 32)];
    self.stepsField.keyboardType = UIKeyboardTypeNumberPad;
    self.stepsField.textAlignment = NSTextAlignmentCenter;
    self.stepsField.font = [UIFont systemFontOfSize:17];
    self.stepsField.textColor = [UIColor labelColor];
    self.stepsField.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.stepsField.layer.cornerRadius = 6;
    self.stepsField.delegate = self;
    [self.stepsField addTarget:self action:@selector(stepsFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [stepsRow addSubview:self.stepsField];

    UIButton *stepPlus = [self roundedButton:@"+100" color:[UIColor systemBlueColor]];
    stepPlus.frame = CGRectMake(stepsRow.bounds.size.width - 72, 6, 64, 32);
    [stepPlus addTarget:self action:@selector(stepPlusTapped:) forControlEvents:UIControlEventTouchUpInside];
    [stepsRow addSubview:stepPlus];
    [self.view addSubview:stepsRow];
    y += 56;

    UIView *quickRow = [[UIView alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 36)];
    NSArray *vals = @[@500, @1000, @5000, @10000];
    CGFloat bw = (quickRow.bounds.size.width - (vals.count - 1) * 10) / vals.count;
    for (NSUInteger i = 0; i < vals.count; i++) {
        UIButton *b = [self roundedButton:[NSString stringWithFormat:@"+%@", vals[i]]
                                  color:[UIColor colorWithRed:0.0 green:0.55 blue:1.0 alpha:1.0]];
        b.frame = CGRectMake(i * (bw + 10), 0, bw, 36);
        b.tag = [vals[i] integerValue];
        [b addTarget:self action:@selector(quickStepTapped:) forControlEvents:UIControlEventTouchUpInside];
        [quickRow addSubview:b];
    }
    [self.view addSubview:quickRow];
    y += 50;

    y = [self addSectionTitle:@"步距 (米/步)" y:y];
    self.ratioSlider = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - margin*2 - 70, 34)];
    self.ratioSlider.minimumValue = 0.5f;
    self.ratioSlider.maximumValue = 0.8f;
    [self.ratioSlider addTarget:self action:@selector(ratioChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.ratioSlider];

    self.ratioLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - margin - 64, y, 64, 34)];
    self.ratioLabel.font = [UIFont systemFontOfSize:17];
    self.ratioLabel.textAlignment = NSTextAlignmentRight;
    self.ratioLabel.textColor = [UIColor labelColor];
    [self.view addSubview:self.ratioLabel];
    y += 46;

    y = [self addSectionTitle:@"距离 (公里)" y:y];
    self.distanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 40)];
    self.distanceLabel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.distanceLabel.layer.cornerRadius = 10;
    self.distanceLabel.clipsToBounds = YES;
    self.distanceLabel.textAlignment = NSTextAlignmentCenter;
    self.distanceLabel.font = [UIFont boldSystemFontOfSize:18];
    self.distanceLabel.textColor = [UIColor systemGreenColor];
    [self.view addSubview:self.distanceLabel];
    y += 56;

    y = [self addSectionTitle:@"楼层" y:y];
    self.flightsField = [[UITextField alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 44)];
    self.flightsField.keyboardType = UIKeyboardTypeNumberPad;
    self.flightsField.textAlignment = NSTextAlignmentCenter;
    self.flightsField.font = [UIFont systemFontOfSize:17];
    self.flightsField.textColor = [UIColor labelColor];
    self.flightsField.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.flightsField.layer.cornerRadius = 10;
    self.flightsField.placeholder = @"手动输入楼层数";
    self.flightsField.delegate = self;
    [self.flightsField addTarget:self action:@selector(flightsFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:self.flightsField];
    y += 60;

    self.applyButton = [self roundedButton:@"写入健康数据"
                               color:[UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1.0]];
    self.applyButton.frame = CGRectMake(margin, y, w - margin*2, 52);
    [self.applyButton addTarget:self action:@selector(applyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.applyButton];
    y += 66;

    // 查看日志 按钮
    UIButton *logBtn = [self roundedButton:@"查看日志" color:[UIColor systemOrangeColor]];
    logBtn.frame = CGRectMake(margin, y, w - margin*2, 44);
    [logBtn addTarget:self action:@selector(viewLogTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:logBtn];
    y += 56;

    // 重启 SpringBoard 按钮
    UIButton *respringBtn = [self roundedButton:@"重启 SpringBoard" color:[UIColor systemTealColor]];
    respringBtn.frame = CGRectMake(margin, y, w - margin*2, 44);
    [respringBtn addTarget:self action:@selector(respringTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:respringBtn];
    y += 56;

    // 重启微信 按钮（关键：tweak 只在微信启动时加载，装完/改完步数后必须重启微信才能生效）
    UIButton *killWCBtn = [self roundedButton:@"重启微信(让步数生效)" color:[UIColor systemIndigoColor]];
    killWCBtn.frame = CGRectMake(margin, y, w - margin*2, 44);
    [killWCBtn addTarget:self action:@selector(killWeChatTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:killWCBtn];
    y += 56;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];

    [self loadSettings];

    // 启动探测：记录关键路径与可写性，方便排查日志去哪了
    HBLog(@"[HealthBoost] App 启动");
    HBLog(@"[HealthBoost] NSHomeDirectory = %@", NSHomeDirectory());
    NSFileManager *fm = [NSFileManager defaultManager];
    HBLog(@"[HealthBoost] 共享路径可写 = %d", [fm isWritableFileAtPath:@"/var/mobile/Media"]);
    HBLog(@"[HealthBoost] 共享日志文件 = %@ (存在=%d)",
          HBSharedLogPath(),
          [fm fileExistsAtPath:HBSharedLogPath()]);

    // 导出 HealthKit 私有 API 清单，用于定位改写样本来源的入口
    HBDumpHealthKitAPIs();
    HBLog(@"[HealthBoost] API 清单已导出: %@", HBAPIDumpPath());

    // 确认 ldid 签的私有 entitlement 是否真的被系统认可
    HBDumpEntitlements();
}

- (CGFloat)addSectionTitle:(NSString *)text y:(CGFloat)y {
    CGFloat w = self.view.bounds.size.width;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, y, w - 48, 22)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:label];
    return y + 26;
}

- (UIButton *)roundedButton:(NSString *)title color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setBackgroundColor:color];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 6;
    return b;
}

// MARK: - Settings

- (void)loadSettings {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:HBSettingsKey];
    if (!d) d = @{@"enabled": @YES, @"steps": @1000, @"ratio": @0.7, @"flights": @5};
    self.enableSwitch.on = [d[@"enabled"] boolValue];
    long steps = [d[@"steps"] longValue];
    if (steps <= 0) steps = 1000;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    double ratio = [d[@"ratio"] doubleValue];
    if (ratio < 0.5) ratio = 0.5;
    if (ratio > 0.8) ratio = 0.8;
    self.ratioSlider.value = (float)ratio;
    self.ratioLabel.text = [NSString stringWithFormat:@"%.1f", ratio];
    long flights = [d[@"flights"] longValue];
    if (flights <= 0) flights = 5;
    self.flightsField.text = [NSString stringWithFormat:@"%ld", flights];
    [self updateDistance];
    [self updateStatus:@"就绪"];
}

- (void)saveSettings {
    long steps = [self.stepsField.text integerValue];
    if (steps < 0) steps = 0;
    double ratio = round(self.ratioSlider.value * 10.0) / 10.0;
    if (ratio < 0.5) ratio = 0.5;
    if (ratio > 0.8) ratio = 0.8;
    long flights = [self.flightsField.text integerValue];
    if (flights < 0) flights = 0;
    NSDictionary *d = @{
        @"enabled": @(self.enableSwitch.isOn),
        @"steps": @(steps),
        @"ratio": @(ratio),
        @"flights": @(flights)
    };
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:d forKey:HBSettingsKey];
    [ud synchronize];
}

- (void)updateDistance {
    long steps = [self.stepsField.text integerValue];
    double ratio = round(self.ratioSlider.value * 10.0) / 10.0;
    double distanceKm = steps * ratio / 1000.0;
    self.distanceLabel.text = [NSString stringWithFormat:@"%.3f 公里", distanceKm];
    self.ratioLabel.text = [NSString stringWithFormat:@"%.1f", ratio];
}

- (void)updateStatus:(NSString *)text {
    self.statusLabel.text = text;
}

// MARK: - Actions

- (void)enableChanged:(UISwitch *)sender {
    [self saveSettings];
    [self updateStatus:sender.isOn ? @"已启用" : @"已禁用"];
}

- (void)stepPlusTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue] + 100;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)stepMinusTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue] - 100;
    if (steps < 0) steps = 0;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)quickStepTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue] + sender.tag;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)stepsFieldChanged:(UITextField *)sender { [self updateDistance]; }
- (void)ratioChanged:(UISlider *)sender { [self updateDistance]; [self saveSettings]; }
- (void)flightsFieldChanged:(UITextField *)sender { [self saveSettings]; }

- (void)respringTapped:(UIButton *)sender {
    HBLog(@"[HealthBoost] respring requested");
    // 用 killall 重启 SpringBoard（roothide 下需要 no-sandbox 权限）
    int pid = fork();
    if (pid == 0) {
        // 子进程
        execlp("killall", "killall", "-HUP", "SpringBoard", nil);
        _exit(1);
    } else if (pid > 0) {
        // 父进程
        [self updateStatus:@"正在重启 SpringBoard..."];
        // 延迟通知完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateStatus:@"已重启"];
            [self showAlert:@"完成" message:@"SpringBoard 已重启"];
        });
    }
}

// 杀掉微信进程，让 tweak 在微信下次启动时重新注入。
// 关键说明：注入微信的 tweak 只在「微信进程启动」那一刻加载。
// 装完 v76 或改完步数后，必须让微信彻底退出再重开，tweak 才会生效。
// （Sileo 安装不会杀微信，所以这一步必须由用户/本按钮触发。）
- (void)killWeChatTapped:(UIButton *)sender {
    HBLog(@"[HealthBoost] 请求重启微信 (killall WeChat)");
    [self updateStatus:@"正在重启微信..."];
    int pid = fork();
    if (pid == 0) {
        // 子进程：-9 强制退出，微信下次打开时加载新 tweak
        execlp("killall", "killall", "-9", "WeChat", nil);
        _exit(1);
    } else if (pid > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateStatus:@"微信已重启，请重新打开微信运动"];
            [self showAlert:@"完成" message:@"微信已强制退出。\n请重新打开微信，进入「微信运动」即可看到写入的步数。\n若仍不对，点「查看日志」把 tweak_log 部分发我。"];
        });
    }
}

- (void)viewLogTapped:(UIButton *)sender {
    NSString *sharedPath = HBSharedLogPath();
    NSString *sandboxPath = HBSandboxLogPath();

    NSString *shared = [NSString stringWithContentsOfFile:sharedPath encoding:NSUTF8StringEncoding error:nil];
    NSString *sandbox = [NSString stringWithContentsOfFile:sandboxPath encoding:NSUTF8StringEncoding error:nil];

    // 取内容更长的那个（更完整）展示
    NSString *content = nil;
    if (shared.length >= sandbox.length) {
        content = shared;
    } else {
        content = sandbox;
    }
    if (!content || content.length == 0) content = @"（暂无 App 日志记录）";

    // 同时读取 tweak 的诊断日志（微信注入是否成功、步数 getter 被调用情况）
    NSString *tweakLogPath = @"/var/mobile/Media/HealthBoost/tweak_log.txt";
    NSString *tweakLog = [NSString stringWithContentsOfFile:tweakLogPath
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (!tweakLog || tweakLog.length == 0) {
        tweakLog = @"（暂无 tweak 日志 —— 说明微信可能还没被注入 / 未重启过微信）";
    }

    // 组合：App 日志 + tweak 日志（tweak 日志最关键）
    NSMutableString *body = [NSMutableString string];
    [body appendString:@"===== App 运行日志 =====\n"];
    [body appendString:content];
    [body appendString:@"\n\n===== 微信注入日志 (tweak) =====\n"];
    [body appendString:tweakLog];

    // 日志已限制在行数内，直接显示完整内容
    NSString *header = @"路径：/var/mobile/Media/HealthBoost/hb_log.txt / tweak_log.txt\n\n";
    NSString *full = [header stringByAppendingString:body];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"运行日志"
                                                                   message:full
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // 复制时只复制日志正文（不含路径头），且最多 30000 字符
        NSString *toCopy = body;
        if (toCopy.length > 30000) {
            toCopy = [toCopy substringFromIndex:toCopy.length - 30000];
        }
        [UIPasteboard generalPasteboard].string = toCopy;
        [self updateStatus:@"日志已复制"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"清空日志" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:sharedPath error:nil];
        [fm removeItemAtPath:sandboxPath error:nil];
        HBLog(@"[HealthBoost] log cleared");
        [self updateStatus:@"日志已清空"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyTapped:(UIButton *)sender {
    [self dismissKeyboard];
    if (self.busy) return;
    if (!self.enableSwitch.isOn) {
        [self showAlert:@"已禁用" message:@"请先打开上方开关"];
        return;
    }
    long steps = [self.stepsField.text integerValue];
    if (steps < 0) steps = 0;
    double ratio = round(self.ratioSlider.value * 10.0) / 10.0;
    if (ratio < 0.5) ratio = 0.5;
    if (ratio > 0.8) ratio = 0.8;
    double distanceMeters = steps * ratio;
    long flights = [self.flightsField.text integerValue];
    if (flights < 0) flights = 0;
    [self saveSettings];

    // 写给微信 tweak 的步数（与 HealthKit 写入相互独立，即便 HealthKit 失败也照样生效）
    HBWriteStepsPreference(steps);

    if (![HKHealthStore isHealthDataAvailable]) {
        [self updateStatus:@"此设备不支持健康数据"];
        [self showAlert:@"不支持" message:@"当前设备不可用 Apple Health"];
        return;
    }

    self.busy = YES;
    [self updateStatus:@"正在请求健康授权..."];
    if (!self.healthStore) self.healthStore = [[HKHealthStore alloc] init];

    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    NSSet *shareTypes = [NSSet setWithObjects:stepType, distType, flightType, nil];

    // 方案3: 静默授权（source_override + authorization_bypass）
    [self.healthStore requestAuthorizationToShareTypes:shareTypes
                                                readTypes:nil
                                             completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                self.busy = NO;
                [self updateStatus:@"健康授权失败"];
                NSString *msg = error ? error.localizedDescription : @"授权失败";
                [self showAlert:@"授权失败" message:msg];
                return;
            }
            [self updateStatus:@"正在寻找 iPhone 源身份..."];
            [self fetchDeviceSourceRevision:^(HKSourceRevision *devRev) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateStatus:@"正在写入健康数据..."];
                    [self writeSamplesSequentially:devRev
                                       stepCount:steps
                                      distanceM:distanceMeters
                                        flights:flights];
                });
            }];
        });
    }];
}

// MARK: - Device source discovery

- (void)fetchDeviceSourceRevision:(void(^)(HKSourceRevision *))completion {
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    // 兼容 iOS 16.5：不用已废弃的 dateByAddingUnit:options:
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.day = -7;
    NSDate *start = [cal dateByAddingComponents:comps toDate:now options:0];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionNone];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                       predicate:pred
                                                           limit:200
                                                 sortDescriptors:nil
                                                  resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        if (error) {
            HBLog(@"[HealthBoost] fetchDeviceSource error: %@", error);
        }
        HKSourceRevision *found = nil;
        NSArray *samples = results ?: @[];
        for (HKSample *s in samples) {
            HKSourceRevision *r = s.sourceRevision;
            if (!r) continue;
            HKSource *src = r.source;
            NSString *bid = src ? src.bundleIdentifier : nil;
            HBLog(@"[HealthBoost] sample source: bid=%@",
                  bid ?: @"nil");
            if (bid == nil) { found = r; break; }
            if ([bid hasPrefix:@"com.apple.health."] && !found) { found = r; }
        }
        HBLog(@"[HealthBoost] found deviceSourceRev: %@", found ?: @"nil");
        if (completion) completion(found);
    }];
    [self.healthStore executeQuery:q];
}

// MARK: - Sequential write (fully async, no blocking)

- (void)writeSamplesSequentially:(HKSourceRevision *)deviceRev
                       stepCount:(long)steps
                     distanceM:(double)distanceMeters
                         flights:(long)flights {
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:now];

    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];

    // Step 1: 查询当天样本
    NSPredicate *todayPred = [HKQuery predicateForSamplesWithStartDate:startOfDay
                                                              endDate:now
                                                            options:HKQueryOptionNone];
    HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                              predicate:todayPred
                                                                  limit:HKObjectQueryNoLimit
                                                        sortDescriptors:nil
                                                         resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        if (error) {
            HBLog(@"[HealthBoost] query error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });
            return;
        }

        NSArray *samples = results ?: @[];
        HBLog(@"[HealthBoost] today %lu samples", (unsigned long)samples.count);

        // 找出要清理的样本：设备源(真机步数) + 本 App 源(往次写入)
        // 关键：实测 source_override 未生效，写入的样本来源其实是 com.sykes.healthboost.app，
        // 若只匹配设备源会导致一条都删不掉 → 每次写入都累加。必须把本 App 源也纳入。
        HKSource *defaultSource = [HKSource defaultSource];
        NSString *myBid = defaultSource.bundleIdentifier;
        HBLog(@"[HealthBoost] defaultSource bid = %@", myBid ?: @"(nil)");

        NSMutableArray *deviceSamples = [NSMutableArray array];
        for (HKSample *s in samples) {
            HKSourceRevision *rev = s.sourceRevision;
            NSString *bid = rev.source.bundleIdentifier;
            BOOL isDevice = (bid == nil);
            BOOL isHealthApp = (bid != nil && [bid hasPrefix:@"com.apple.health."]);
            BOOL isMine = (myBid != nil && bid != nil && [bid isEqualToString:myBid]);
            if (isDevice || isHealthApp || isMine) {
                [deviceSamples addObject:s];
            }
        }
        HBLog(@"[HealthBoost] samples to delete: %lu (of %lu)",
              (unsigned long)deviceSamples.count, (unsigned long)samples.count);

        // Step 2: 删除设备源样本（用 dispatch_group，内部原子计数，避免竞态）
        // 注意：旧代码用 __block NSUInteger remaining + --remaining 手工计数，
        // HealthKit 回调可能并发执行，非原子的自减会丢更新，导致 remaining 永远碰不到 0，
        // 结果是「样本删了但新样本没写」→ 健康里变空。必须用 dispatch_group。
        __weak typeof(self) weakSelf = self;
        if (deviceSamples.count > 0) {
            dispatch_group_t group = dispatch_group_create();
            for (HKSample *s in deviceSamples) {
                dispatch_group_enter(group);
                [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e) {
                    HBLog(@"[HealthBoost] delete %@: ok=%d err=%@", s.sampleType.identifier, ok, e ?: @"nil");
                    dispatch_group_leave(group);
                }];
            }
            // 用 notify 异步等待，绝不能用 dispatch_group_wait 阻塞——
            // 本回调可能就跑在 HealthKit 的串行队列上，阻塞会让删除回调永远无法送达。
            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                HBLog(@"[HealthBoost] all deletes done (%lu 条)", (unsigned long)deviceSamples.count);
                HBLog(@"[HealthBoost] start writing: steps=%ld dist=%.1f flights=%ld", steps, distanceMeters, flights);
                [weakSelf _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];
            });
        } else {
            HBLog(@"[HealthBoost] no device samples to delete");
            dispatch_async(dispatch_get_main_queue(), ^{
                HBLog(@"[HealthBoost] start writing: steps=%ld dist=%.1f flights=%ld", steps, distanceMeters, flights);
                [weakSelf _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];
            });
        }
    }];
    [self.healthStore executeQuery:query];
}

// 优先用私有 _saveObjects:atomically:skipInsertionFilter:completion: 写入。
// skipInsertionFilter=YES 有可能跳过 healthd 的来源过滤，让注入的 device source 得以保留。
// 调用前先核对参数个数（self + _cmd + 4 = 6），不符就退回公开 API，避免签名不符导致崩溃。
- (void)saveSamplePrivately:(HKQuantitySample *)sample completion:(void (^)(BOOL success, NSError *error))completion {
    SEL privSel = NSSelectorFromString(@"_saveObjects:atomically:skipInsertionFilter:completion:");
    Method m = privSel ? class_getInstanceMethod([HKHealthStore class], privSel) : NULL;
    unsigned int nargs = m ? method_getNumberOfArguments(m) : 0;
    HBLog(@"[HealthBoost] _saveObjects 参数个数=%u (期望 6)", nargs);

    if (!m || nargs != 6) {
        HBLog(@"[HealthBoost] 私有 save 不可用，退回公开 saveObject");
        [self.healthStore saveObject:sample withCompletion:completion];
        return;
    }

    @try {
        NSMethodSignature *sig = [self.healthStore methodSignatureForSelector:privSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:privSel];

        NSArray *objs = @[sample];
        BOOL atomically = YES;
        BOOL skipFilter = YES;
        void (^cb)(BOOL, NSError *) = [completion copy];

        [inv setArgument:&objs      atIndex:2];
        [inv setArgument:&atomically atIndex:3];
        [inv setArgument:&skipFilter atIndex:4];
        [inv setArgument:&cb        atIndex:5];
        [inv invokeWithTarget:self.healthStore];
        HBLog(@"[HealthBoost] 已用私有 _saveObjects(skipInsertionFilter:YES) 提交");
    } @catch (NSException *e) {
        HBLog(@"[HealthBoost] 私有 save 异常: %@ -> 退回公开 API", e);
        [self.healthStore saveObject:sample withCompletion:completion];
    }
}

// 写入后回读验证：查当天步数总和，确认健康库里到底有没有数据
- (void)verifyStepsWritten {
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSDate *startOfDay = [[NSCalendar currentCalendar] startOfDayForDate:now];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];

    HKStatisticsQuery *q = [[HKStatisticsQuery alloc] initWithQuantityType:stepType
                                                  quantitySamplePredicate:pred
                                                                  options:HKStatisticsOptionCumulativeSum
                                                        completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {
        if (error) {
            HBLog(@"[HealthBoost] VERIFY error: %@", error);
            return;
        }
        HKQuantity *sum = [result sumQuantity];
        double v = sum ? [sum doubleValueForUnit:[HKUnit countUnit]] : 0;
        HBLog(@"[HealthBoost] VERIFY 当天步数总和 = %.0f", v);

        // 逐条列出来源，确认样本到底记在谁名下
        HKSampleQuery *sq = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                            predicate:pred
                                                                limit:50
                                                      sortDescriptors:nil
                                                       resultsHandler:^(HKSampleQuery *q2, NSArray *results2, NSError *e2) {
            HBLog(@"[HealthBoost] VERIFY 当天样本条数 = %lu", (unsigned long)(results2 ?: @[]).count);
            for (HKSample *s in (results2 ?: @[])) {
                NSString *bid = s.sourceRevision.source.bundleIdentifier;
                if ([s isKindOfClass:[HKQuantitySample class]]) {
                    HKQuantitySample *qs = (HKQuantitySample *)s;
                    double sv = [qs.quantity doubleValueForUnit:[HKUnit countUnit]];
                    HBLog(@"[HealthBoost] VERIFY 样本: %.0f 步, 来源=%@", sv, bid ?: @"(nil=设备源)");
                }
            }
        }];
        [self.healthStore executeQuery:sq];
    }];
    [self.healthStore executeQuery:q];
}

- (void)_writeSteps:(long)steps dist:(double)distM flights:(long)flights deviceRev:(HKSourceRevision *)deviceRev index:(NSUInteger)index {
    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];

    HKQuantityType *type;
    double value;
    if (index == 0)      { type = stepType;    value = (double)steps; }
    else if (index == 1) { type = distType;    value = distM; }
    else                 { type = flightType;  value = (double)flights; }

    NSDate *sampleNow = [NSDate date];
    HKUnit *unit = [HKUnit countUnit];
    if (type == distType) unit = [HKUnit meterUnit];
    HKQuantity *q = [HKQuantity quantityWithUnit:unit doubleValue:value];
    HKQuantitySample *sample = HBMakeDeviceSample(type, q, sampleNow, sampleNow, deviceRev);

    if (!sample) {
        HBLog(@"[HealthBoost] sample creation failed");
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:nil busy:YES]; });
        return;
    }

    HBLog(@"[HealthBoost] saving %@ value=%.2f", type.identifier, value);
    [self saveSamplePrivately:sample completion:^(BOOL success, NSError *error) {
        HBLog(@"[HealthBoost] save %@: ok=%d err=%@", type.identifier, success, error ?: @"nil");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });
            return;
        }
        if (index < 2) {
            // 继续写下一个
            [self _writeSteps:steps dist:distM flights:flights deviceRev:deviceRev index:index + 1];
        } else {
            // 全部写完
            HBLog(@"[HealthBoost] all writes complete");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishSuccess:deviceRev];
                // 回读验证：确认健康库里真的有数据、来源是谁（结果只进日志）
                [self verifyStepsWritten];
            });
        }
    }];
}

- (void)finishSuccess:(HKSourceRevision *)deviceRev {
    self.busy = NO;
    [self updateStatus:@"已写入健康数据"];
    NSString *mode = deviceRev ? @"设备源(已注入)" : @"设备源(仅 HKDevice)";
    NSString *msg = [NSString stringWithFormat:
        @"已写入 Apple Health\n来源模式：%@\n\n"
        @"要让「微信运动」也显示，请点下方的\n"
        @"「重启微信(让步数生效)」按钮，\n"
        @"然后重新打开微信运动查看。\n"
        @"若微信仍不对，点「查看日志」把内容发我。", mode];
    [self showAlert:@"完成" message:msg];
}

- (void)finishWithError:(NSError *)error busy:(BOOL)busyFlag {
    (void)busyFlag;
    self.busy = NO;
    [self updateStatus:@"写入失败"];
    NSString *msg = error ? error.localizedDescription : @"未知错误";
    [self showAlert:@"写入失败" message:msg];
}

// MARK: - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self updateDistance];
    [self saveSettings];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSCharacterSet *allowed = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if (![allowed characterIsMember:c]) return NO;
    }
    return YES;
}

- (void)dismissKeyboard {
    [self.stepsField resignFirstResponder];
    [self.flightsField resignFirstResponder];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// MARK: - App Delegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[HBMainViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
