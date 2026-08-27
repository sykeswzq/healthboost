// HealthBoost - iOS App that writes steps / distance / flights directly to Apple Health
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

static NSString * const HBSettingsKey = @"com.sykes.healthboost.settings";

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
@property (copy, nonatomic) NSString *lastWriteMode;
@end

@implementation HBMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    CGFloat w = self.view.bounds.size.width;
    CGFloat margin = 24;
    CGFloat y = 70;

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 40)];
    title.text = @"HealthBoost";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = [UIColor labelColor];
    [self.view addSubview:title];
    y += 54;

    // Status
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 36)];
    self.statusLabel.text = @"配置加载中...";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];
    y += 46;

    // Enable toggle
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

    // Steps section
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

    // Quick buttons
    UIView *quickRow = [[UIView alloc] initWithFrame:CGRectMake(margin, y, w - margin*2, 36)];
    NSArray *vals = @[@500, @1000, @5000, @10000];
    CGFloat bw = (quickRow.bounds.size.width - (vals.count - 1) * 10) / vals.count;
    for (NSUInteger i = 0; i < vals.count; i++) {
        UIButton *b = [self roundedButton:[NSString stringWithFormat:@"+%@", vals[i]] color:[UIColor colorWithRed:0.0 green:0.55 blue:1.0 alpha:1.0]];
        b.frame = CGRectMake(i * (bw + 10), 0, bw, 36);
        b.tag = [vals[i] integerValue];
        [b addTarget:self action:@selector(quickStepTapped:) forControlEvents:UIControlEventTouchUpInside];
        [quickRow addSubview:b];
    }
    [self.view addSubview:quickRow];
    y += 50;

    // Ratio section
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

    // Distance section
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

    // Flights section
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

    // Apply button
    self.applyButton = [self roundedButton:@"写入健康数据" color:[UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1.0]];
    self.applyButton.frame = CGRectMake(margin, y, w - margin*2, 52);
    [self.applyButton addTarget:self action:@selector(applyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.applyButton];
    y += 66;

    // Tapping outside dismisses keyboard
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];

    [self loadSettings];
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

// MARK: - Settings (persisted in app sandbox, no /var/jb writes)

- (void)loadSettings {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:HBSettingsKey];
    if (!d) {
        d = @{@"enabled": @YES, @"steps": @1000, @"ratio": @0.7, @"flights": @5};
    }
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
    double distanceMeters = steps * ratio;
    double distanceKm = distanceMeters / 1000.0;
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
    long steps = [self.stepsField.text integerValue];
    steps += 100;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)stepMinusTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue];
    steps -= 100;
    if (steps < 0) steps = 0;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)quickStepTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue];
    steps += sender.tag;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveSettings];
}

- (void)stepsFieldChanged:(UITextField *)sender {
    [self updateDistance];
}

- (void)ratioChanged:(UISlider *)sender {
    [self updateDistance];
    [self saveSettings];
}

- (void)flightsFieldChanged:(UITextField *)sender {
    [self saveSettings];
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
    if (!self.healthStore) {
        self.healthStore = [[HKHealthStore alloc] init];
    }

    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    NSSet *shareTypes = [NSSet setWithObjects:stepType, distType, flightType, nil];
    NSSet *readTypes = [NSSet setWithObjects:stepType, distType, flightType, nil];

    [self.healthStore requestAuthorizationToShareTypes:shareTypes readTypes:readTypes completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                self.busy = NO;
                [self updateStatus:@"健康授权失败"];
                NSString *msg = error ? error.localizedDescription : @"你可能拒绝了健康数据写入权限。请到 设置 → 隐私与安全 → 健康 → HealthBoost 打开权限。";
                [self showAlert:@"授权失败" message:msg];
                return;
            }
            // 方案2探针：借用今日真实「设备源」样本的 sourceRevision（iPhone 身份），
            // 配合 source_override 私有权限，尝试让 healthd 接受伪造来源 → 微信运动按设备源读取
            [self fetchDeviceSourceRevision:^(HKSourceRevision *devRev) {
                dispatch_async(dispatch_get_main_queue(), ^{
                self.lastWriteMode = devRev ? @"设备源伪装" : @"App源(未找到设备样本)";
                [self updateStatus:@"正在写入健康数据..."];
                [self saveSample:stepType value:(double)steps unit:[HKUnit countUnit] deviceRev:devRev completion:^(BOOL s1, NSError *e1) {
                [self saveSample:distType value:distanceMeters unit:[HKUnit meterUnit] deviceRev:devRev completion:^(BOOL s2, NSError *e2) {
                    [self saveSample:flightType value:(double)flights unit:[HKUnit countUnit] deviceRev:devRev completion:^(BOOL s3, NSError *e3) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.busy = NO;
                            BOOL allOK = s1 && s2 && s3;
                            double km = distanceMeters / 1000.0;
                            if (allOK) {
                                NSString *msg = [NSString stringWithFormat:@"已写入 Apple Health：\n步数 %ld\n距离 %.3f 公里\n楼层 %ld\n来源模式：%@", steps, km, flights, self.lastWriteMode];
                                [self updateStatus:@"已写入健康数据"];
                                [self showAlert:@"完成" message:msg];
                            } else {
                                [self updateStatus:@"部分写入失败"];
                                NSString *detail = [NSString stringWithFormat:@"步数:%@ 距离:%@ 楼层:%@",
                                                    s1 ? @"OK" : @"失败", s2 ? @"OK" : @"失败", s3 ? @"OK" : @"失败"];
                                [self showAlert:@"写入未完成" message:detail];
                            }
                        });
                    }];
                }];
            }];
        });
    }];
  });
}];
}

// 方案2探针：从今日(近7天)真实样本里借一个「设备源」的 sourceRevision（iPhone 身份）。
// 设备源样本的来源 bundleIdentifier 通常为 nil 或特殊值（不是本 App、不是手动「健康」入口），
// 优先选 bundleIdentifier==nil 的（即真正由设备产生的数据），找不到再退而求其次。
- (void)fetchDeviceSourceRevision:(void(^)(HKSourceRevision *rev))completion {
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSDate *start = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:now options:0];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionNone];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                       predicate:pred
                                                           limit:300
                                                 sortDescriptors:nil
                                                  resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        HKSourceRevision *found = nil;
        NSString *mine = [[HKSource defaultSource] bundleIdentifier];
        for (HKSample *s in results) {
            HKSourceRevision *r = s.sourceRevision;
            NSString *bid = r.source.bundleIdentifier;
            if (bid == nil) { found = r; break; }            // 设备直接产生，bundle=nil，最像 iPhone 源
            if (![bid isEqualToString:mine] && ![bid isEqualToString:@"com.apple.Health"]) {
                if (!found) found = r;                        // 退而求其次：非本 App、非手动入口
            }
        }
        if (completion) completion(found);
    }];
    [self.healthStore executeQuery:q];
}

// 写入前先删除当天「本 App 来源」的同类型旧样本，避免多次写入累加（5000+5100=10100）
- (void)saveSample:(HKQuantityType *)type value:(double)value unit:(HKUnit *)unit deviceRev:(HKSourceRevision *)deviceRev completion:(void(^)(BOOL success, NSError *error))completion {
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:now];

    HKSource *mySource = [HKSource defaultSource];
    NSPredicate *pred = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone],
        [HKQuery predicateForObjectsFromSource:mySource]
    ]];

    void (^finishSave)(void) = ^{
        HKQuantity *quantity = [HKQuantity quantityWithUnit:unit doubleValue:value];
        HKDevice *device = [HKDevice localDevice];
        HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type
                                                                  quantity:quantity
                                                                 startDate:now
                                                                   endDate:now
                                                                     device:device
                                                                  metadata:nil];
        // 方案2探针：把借来的「设备源 sourceRevision」通过私有 ivar 挂到样本上，
        // 配合 entitlements 的 source_override 私有权限，让 healthd 接受伪造来源。
        // KVC 设私有 ivar 可能抛 NSUnknownKeyException，必须包 @try；失败则回退为 App 源写入。
        BOOL applied = NO;
        if (deviceRev) {
            @try {
                [sample setValue:deviceRev forKey:@"_sourceRevision"];
                applied = YES;
            } @catch (NSException *e1) {
                @try { [sample setValue:deviceRev forKey:@"sourceRevision"]; applied = YES; }
                @catch (NSException *e2) { applied = NO; }
            }
        }
        if (applied) self.lastWriteMode = @"设备源伪装(已注入)";
        [self.healthStore saveObject:sample withCompletion:^(BOOL success, NSError *error) {
            if (completion) completion(success, error);
        }];
    };

    HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:type
                                                           predicate:pred
                                                               limit:HKObjectQueryNoLimit
                                                     sortDescriptors:nil
                                                      resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        if (error) { if (completion) completion(NO, error); return; }
        if (results.count == 0) { finishSave(); return; }
        // 先删旧样本，再写新绝对值，保证 HealthKit 显示的是设定值而非累加值
        dispatch_group_t grp = dispatch_group_create();
        for (HKSample *s in results) {
            dispatch_group_enter(grp);
            [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e) {
                dispatch_group_leave(grp);
            }];
        }
        dispatch_group_notify(grp, dispatch_get_main_queue(), finishSave);
    }];
    [self.healthStore executeQuery:query];
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
        if (![allowed characterIsMember:c]) {
            return NO;
        }
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
