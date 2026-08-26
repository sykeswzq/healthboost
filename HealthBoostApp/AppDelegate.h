#import <UIKit/UIKit.h>
#import "AppDelegate.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    
    UIViewController *viewController = [[UIViewController alloc] init];
    viewController.view.backgroundColor = [UIColor whiteColor];
    
    // Add title label
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 375, 50)];
    titleLabel.text = @"HealthBoost";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [viewController.view addSubview:titleLabel];
    
    // Add config description
    UILabel *descLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 335, 60)];
    descLabel.text = @"通过 Settings 应用配置 HealthBoost\n\n在设置中找到 HealthBoost 即可配置";
    descLabel.textAlignment = NSTextAlignmentCenter;
    descLabel.font = [UIFont systemFontOfSize:16];
    [viewController.view addSubview:descLabel];
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:viewController];
    self.window.rootViewController = navController;
    [self.window makeKeyAndVisible];
    
    return YES;
}

@end
