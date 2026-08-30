// HealthBoost - iOS App that writes steps / distance / flights to Apple Health as device source
// 使用 com.apple.private.healthkit.source_override + authorization_bypass 私有权限
// 让写出的 step count 来源伪装成 iPhone 设备源，从而被微信运动等应用读取
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

static NSString * const HBSettingsKey = @"com.sykes.healthboost.settings";

// MARK: - Logging helper
// 日志同时写到两个位置：
//   1) /var/mobile/Media/HealthBoost/hb_log.txt  —— Files App「我的 iPhone」里能直接看到
//   2) App 沙盒 Documents/hb_log.txt              —— 保底，App 内「查看日志」能读
// App 带 com.apple.private.security.no-sandbox，可写沙盒外路径。

// 追加一行到指定路径（文件不存在会自动创建）
static void HBAppendLine(NSString *path, NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {
        // 忽略写入异常，避免日志逻辑本身导致崩溃
    }
    [fh closeFile];
}

// 外部共享日志路径（Files App 可见）
static NSString *HBSharedLogPath(void) {
    return @"/var/mobile/Media/HealthBoost/hb_log.txt";
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

- (void)viewLogTapped:(UIButton *)sender {
    NSString *sharedPath = HBSharedLogPath();
    NSString *sandboxPath = HBSandboxLogPath();

    NSString *shared = [NSString stringWithContentsOfFile:sharedPath encoding:NSUTF8StringEncoding error:nil];
    NSString *sandbox = [NSString stringWithContentsOfFile:sandboxPath encoding:NSUTF8StringEncoding error:nil];

    // 取内容更长的那个（更完整）展示
    NSString *content = nil;
    NSString *usedPath = nil;
    if (shared.length >= sandbox.length) {
        content = shared;
        usedPath = sharedPath;
    } else {
        content = sandbox;
        usedPath = sandboxPath;
    }
    if (!content || content.length == 0) content = @"（暂无日志记录）";

    // 只保留最后 6000 字符，避免弹窗内容过长被系统截断
    NSString *shown = content;
    if (shown.length > 6000) {
        shown = [@"...（已截断，仅显示最后部分）\n" stringByAppendingString:[shown substringFromIndex:shown.length - 6000]];
    }

    NSString *full = [NSString stringWithFormat:@"共享路径：/var/mobile/Media/HealthBoost/\n沙盒路径：%@\n\n%@", sandboxPath, shown];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"运行日志"
                                                                   message:full
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = content;
        [self updateStatus:@"日志已复制到剪贴板"];
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

        // 找出设备源样本
        NSMutableArray *deviceSamples = [NSMutableArray array];
        for (HKSample *s in samples) {
            NSString *bid = s.source.bundleIdentifier;
            if (bid == nil || [bid hasPrefix:@"com.apple.health."]) {
                [deviceSamples addObject:s];
            }
        }
        HBLog(@"[HealthBoost] device samples to delete: %lu", (unsigned long)deviceSamples.count);

        // Step 2: 删除设备源样本（异步）
        if (deviceSamples.count > 0) {
            __block NSUInteger remaining = deviceSamples.count;
            for (HKSample *s in deviceSamples) {
                [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e) {
                    HBLog(@"[HealthBoost] delete %@: ok=%d err=%@", s.sampleType.identifier, ok, e ?: @"nil");
                    if (--remaining == 0) {
                        HBLog(@"[HealthBoost] all deletes done");
                        // Step 3: 开始写样本
                        [self _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];
                    }
                }];
            }
        } else {
            // 没有设备源样本，直接开始写
            [self _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];
        }
    }];
    [self.healthStore executeQuery:query];
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
    [self.healthStore saveObject:sample withCompletion:^(BOOL success, NSError *error) {
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
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishSuccess:deviceRev]; });
        }
    }];
}

- (void)finishSuccess:(HKSourceRevision *)deviceRev {
    self.busy = NO;
    [self updateStatus:@"已写入健康数据"];
    NSString *mode = deviceRev ? @"设备源(已注入)" : @"设备源(仅 HKDevice)";
    [self showAlert:@"完成" message:[NSString stringWithFormat:@"已写入 Apple Health\n来源模式：%@", mode]];
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
