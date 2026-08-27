// HealthBoost - Simple iOS App for launching daemon
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

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    
    // Create simple UI
    UIView *container = [[UIView alloc] initWithFrame:self.window.bounds];
    container.backgroundColor = [UIColor whiteColor];
    
    // Title label
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, 375, 50)];
    titleLabel.text = @"HealthBoost";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:28];
    titleLabel.textColor = [UIColor darkGrayColor];
    [container addSubview:titleLabel];
    
    // Status label
    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 150, 335, 40)];
    statusLabel.text = @"Tap to trigger HealthBoost";
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:16];
    statusLabel.textColor = [UIColor grayColor];
    [container addSubview:statusLabel];
    
    // Trigger button
    UIButton *triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    triggerButton.frame = CGRectMake(50, 220, 275, 50);
    [triggerButton setTitle:@"Trigger Boost" forState:UIControlStateNormal];
    [triggerButton setBackgroundColor:[UIColor colorWithRed:0.23 green:0.23 blue:0.25 alpha:1.0]];
    [triggerButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    triggerButton.layer.cornerRadius = 10;
    [triggerButton addTarget:self action:@selector(triggerBoost) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:triggerButton];
    
    // Settings button
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsButton.frame = CGRectMake(50, 290, 275, 50);
    [settingsButton setTitle:@"Open Settings" forState:UIControlStateNormal];
    [settingsButton setBackgroundColor:[UIColor systemBlueColor]];
    [settingsButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    settingsButton.layer.cornerRadius = 10;
    [settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:settingsButton];
    
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.rootViewController.view = container;
    [self.window makeKeyAndVisible];
    
    return YES;
}

- (void)triggerBoost {
    // Read config
    NSString *configPath = @"/var/jb/Library/HealthBoost/config.plist";
    NSData *configData = [NSData dataWithContentsOfFile:configPath];
    if (!configData) {
        [self showAlert:@"Error" message:@"Config file not found"];
        return;
    }
    
    NSDictionary *config = [NSPropertyListSerialization propertyListWithData:configData options:0 format:nil error:nil];
    BOOL enabled = [[config[@"enabled"] stringValue] boolValue];
    
    if (!enabled) {
        [self showAlert:@"Disabled" message:@"HealthBoost is disabled. Enable it in Settings."];
        return;
    }
    
    // Trigger daemon
    hb_run("launchctl kickstart -k system/com.sykes.healthboost 2>/dev/null");
    
    // Read values
    double steps = [[config[@"steps"] stringValue] doubleValue];
    double distance = [[config[@"distance"] stringValue] doubleValue];
    double flights = [[config[@"flights"] stringValue] doubleValue];
    
    NSString *msg = [NSString stringWithFormat:@"Triggered: %.0f steps, %.2fm, %.0f flights", steps, distance, flights];
    [self showAlert:@"HealthBoost" message:msg];
}

- (void)openSettings {
    // Open iOS Settings
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"prefs:root=SETTINGS"] options:@{} completionHandler:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
