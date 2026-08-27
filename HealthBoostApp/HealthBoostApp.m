// HealthBoost - iOS App for setting steps / distance / floors and triggering daemon
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>

static void hb_run(const char *cmd) {
    pid_t pid;
    const char *argv[] = {"/bin/sh", "-c", cmd, NULL};
    if (posix_spawn(&pid, "/bin/sh", NULL, NULL, (char * const *)argv, NULL) == 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

static NSString *HBConfigPath(void) {
    return @"/var/jb/Library/HealthBoost/config.plist";
}

static BOOL HBWriteConfig(NSDictionary *config) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:config
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (!data) return NO;

    NSString *path = HBConfigPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];

    // 确保目录存在且任何人可写（roothide 下 App 以 mobile 运行，避免依赖目录写权限）
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm setAttributes:@{NSFilePosixPermissions: @0777} ofItemAtPath:dir error:nil];

    // 先放开文件权限，确保即使由 root 创建，mobile 也能覆盖写入
    if ([fm fileExistsAtPath:path]) {
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:nil];
    }

    // 非原子写：直接覆盖，避免原子写需要在目录内创建临时文件（要求目录写权限）
    BOOL ok = [data writeToFile:path atomically:NO];
    if (ok) {
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:nil];
    }
    return ok;
}

static NSDictionary *HBReadConfig(void) {
    NSData *data = [NSData dataWithContentsOfFile:HBConfigPath()];
    if (!data) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
}

static double HBDoubleValue(id obj, double fallback) {
    if (!obj) return fallback;
    if ([obj isKindOfClass:[NSNumber class]]) return [obj doubleValue];
    if ([obj isKindOfClass:[NSString class]]) return [obj doubleValue];
    return fallback;
}

static long HBIntValue(id obj, long fallback) {
    if (!obj) return fallback;
    if ([obj isKindOfClass:[NSNumber class]]) return [obj longValue];
    if ([obj isKindOfClass:[NSString class]]) return [obj integerValue];
    return fallback;
}

static BOOL HBBoolValue(id obj, BOOL fallback) {
    if (!obj) return fallback;
    if ([obj isKindOfClass:[NSNumber class]]) return [obj boolValue];
    if ([obj isKindOfClass:[NSString class]]) return [obj boolValue];
    return fallback;
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
    [self.view addSubview:self.flightsField];
    y += 60;

    // Apply button
    self.applyButton = [self roundedButton:@"写入健康数据" color:[UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1.0]];
    self.applyButton.frame = CGRectMake(margin, y, w - margin*2, 52);
    [self.applyButton addTarget:self action:@selector(applyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.applyButton];
    y += 66;

    // Tap to dismiss keyboard
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];

    [self loadConfig];
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

// MARK: - Config

- (void)loadConfig {
    NSDictionary *config = HBReadConfig();
    if (!config) {
        // Create default config
        config = @{
            @"enabled": @YES,
            @"steps": @1000,
            @"ratio": @0.7,
            @"distance": @700.0,
            @"flights": @5
        };
        HBWriteConfig(config);
    }

    self.enableSwitch.on = HBBoolValue(config[@"enabled"], YES);

    long steps = HBIntValue(config[@"steps"], 1000);
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];

    double ratio = HBDoubleValue(config[@"ratio"], 0.7);
    if (ratio < 0.5) ratio = 0.5;
    if (ratio > 0.8) ratio = 0.8;
    self.ratioSlider.value = (float)ratio;
    self.ratioLabel.text = [NSString stringWithFormat:@"%.1f", ratio];

    long flights = HBIntValue(config[@"flights"], 5);
    self.flightsField.text = [NSString stringWithFormat:@"%ld", flights];

    [self updateDistance];
    [self updateStatus:@"已加载配置"];
}

- (BOOL)saveCurrentValues {
    long steps = [self.stepsField.text integerValue];
    if (steps < 0) steps = 0;

    double ratio = round(self.ratioSlider.value * 10.0) / 10.0;
    double distanceMeters = steps * ratio;

    long flights = [self.flightsField.text integerValue];
    if (flights < 0) flights = 0;

    NSDictionary *config = @{
        @"enabled": @(self.enableSwitch.isOn),
        @"steps": @(steps),
        @"ratio": @(ratio),
        @"distance": @(distanceMeters),
        @"flights": @(flights)
    };
    return HBWriteConfig(config);
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
    if (![self saveCurrentValues]) {
        [self showAlert:@"保存失败" message:@"无法写入配置文件，请检查文件权限"];
        return;
    }
    [self updateStatus:sender.isOn ? @"已启用" : @"已禁用"];
}

- (void)stepPlusTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue];
    steps += 100;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveCurrentValues];
}

- (void)stepMinusTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue];
    steps -= 100;
    if (steps < 0) steps = 0;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveCurrentValues];
}

- (void)quickStepTapped:(UIButton *)sender {
    long steps = [self.stepsField.text integerValue];
    steps += sender.tag;
    self.stepsField.text = [NSString stringWithFormat:@"%ld", steps];
    [self updateDistance];
    [self saveCurrentValues];
}

- (void)stepsFieldChanged:(UITextField *)sender {
    [self updateDistance];
}

- (void)ratioChanged:(UISlider *)sender {
    [self updateDistance];
    [self saveCurrentValues];
}

- (void)flightsFieldChanged:(UITextField *)sender {
    [self saveCurrentValues];
}

- (void)applyTapped:(UIButton *)sender {
    [self dismissKeyboard];

    if (![self saveCurrentValues]) {
        [self showAlert:@"保存失败" message:@"无法写入 /var/jb/Library/HealthBoost/config.plist，请检查文件权限或卸载重装"];
        return;
    }

    if (!self.enableSwitch.isOn) {
        [self showAlert:@"已禁用" message:@"请先打开上方开关"];
        return;
    }

    [self updateStatus:@"正在写入..."];

    // Kick daemon
    hb_run("launchctl kickstart -k system/com.sykes.healthboost 2>/dev/null || true");

    // Read back to confirm
    NSDictionary *config = HBReadConfig();
    long steps = HBIntValue(config[@"steps"], 0);
    double distanceMeters = HBDoubleValue(config[@"distance"], 0);
    double distanceKm = distanceMeters / 1000.0;
    long flights = HBIntValue(config[@"flights"], 0);

    NSString *msg = [NSString stringWithFormat:@"已写入：步数 %ld，距离 %.3f 公里，楼层 %ld", steps, distanceKm, flights];
    [self updateStatus:msg];
    [self showAlert:@"完成" message:msg];
}

// MARK: - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self updateDistance];
    [self saveCurrentValues];
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
