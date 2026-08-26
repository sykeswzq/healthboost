// HealthBoost Settings - iOS Settings Extension
// Simple Settings.bundle compatible implementation
// Written: 2026-08-26

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface HealthBoostSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation HealthBoostSettingsViewController {
    UITextField *_stepsField;
    UITextField *_distanceField;
    UITextField *_flightsField;
    UISwitch *_enabledSwitch;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"HealthBoost";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(saveSettings)];
    
    // Load saved values
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Add custom header row
    NSNumber *enabled = [defaults objectForKey:@"healthboost_enabled"];
    NSString *steps = [defaults stringForKey:@"steps_value"] ?: @"0";
    NSString *distance = [defaults stringForKey:@"distance_value"] ?: @"0";
    NSString *flights = [defaults stringForKey:@"flights_value"] ?: @"0";
    
    NSLog(@"HealthBoost Settings loaded: enabled=%@, steps=%@, distance=%@, flights=%@", 
          enabled ?: @"NO", steps, distance, flights);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; // Enabled toggle
    return 3; // Steps, distance, flights
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellID = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellID];
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    if (indexPath.section == 0) {
        // Enable/Disable toggle
        cell.textLabel.text = @"Enable HealthBoost";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        
        _enabledSwitch = [[UISwitch alloc] init];
        _enabledSwitch.on = [defaults boolForKey:@"healthboost_enabled"];
        [_enabledSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = _enabledSwitch;
    } else if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Steps";
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                _stepsField = [[UITextField alloc] init];
                _stepsField.keyboardType = UIKeyboardTypeNumberPad;
                _stepsField.text = [defaults stringForKey:@"steps_value"] ?: @"0";
                [_stepsField addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
                cell.accessoryView = _stepsField;
                break;
            case 1:
                cell.textLabel.text = @"Distance (meters)";
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                _distanceField = [[UITextField alloc] init];
                _distanceField.keyboardType = UIKeyboardTypeDecimalPad;
                _distanceField.text = [defaults stringForKey:@"distance_value"] ?: @"0";
                [_distanceField addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
                cell.accessoryView = _distanceField;
                break;
            case 2:
                cell.textLabel.text = @"Flights Climbed";
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                _flightsField = [[UITextField alloc] init];
                _flightsField.keyboardType = UIKeyboardTypeNumberPad;
                _flightsField.text = [defaults stringForKey:@"flights_value"] ?: @"0";
                [_flightsField addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
                cell.accessoryView = _flightsField;
                break;
        }
    }
    
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:@"healthboost_enabled"];
    [defaults synchronize];
}

- (void)textFieldChanged:(UITextField *)sender {
    // Values are saved on demand
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    BOOL enabled = _enabledSwitch.on;
    NSString *stepsStr = _stepsField.text ?: @"0";
    NSString *distanceStr = _distanceField.text ?: @"0";
    NSString *flightsStr = _flightsField.text ?: @"0";
    
    [defaults setBool:enabled forKey:@"healthboost_enabled"];
    [defaults setObject:stepsStr forKey:@"steps_value"];
    [defaults setObject:distanceStr forKey:@"distance_value"];
    [defaults setObject:flightsStr forKey:@"flights_value"];
    [defaults synchronize];
    
    // Write to config file for daemon to read
    NSDictionary *config = @{
        @"enabled": @(enabled),
        @"steps": stepsStr,
        @"distance": distanceStr,
        @"flights": flightsStr
    };
    
    NSData *configData = [NSPropertyListSerialization dataWithPropertyList:config
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                      options:0
                                                                        error:nil];
    
    NSString *configPath = @"/var/jb/Library/HealthBoost/config.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:@"/var/jb/Library/HealthBoost"
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
    [fm createFileAtPath:configPath contents:configData attributes:nil];
    
    NSLog(@"HealthBoost settings saved: enabled=%d, steps=%@, distance=%@, flights=%@",
          enabled, stepsStr, distanceStr, flightsStr);
    
    // Show success alert
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Settings Saved"
                                                                   message:@"HealthBoost configuration has been updated."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    [rootVC presentViewController:alert animated:YES completion:nil];
    
    // Reload daemon if enabled
    if (enabled) {
        system("launchctl kickstart -k system/com.sykes.healthboost 2>/dev/null || true");
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Toggle to enable/disable the daemon. Save to apply.";
    return nil;
}

@end
