// Simple settings view controller for HealthBoost

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SimpleSettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation SimpleSettingsVC {
    UITableView *_tableView;
    NSMutableArray *_settings;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"HealthBoost";
    self.view.backgroundColor = [UIColor groupedBackgroundColor];
    
    // Load settings
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _settings = [NSMutableArray arrayWithObjects:
                 @[@"Enable HealthBoost", @"healthboost_enabled", @"switch"],
                 @[@"Steps", @"steps_value", @"text"],
                 @[@"Distance (m)", @"distance_value", @"text"],
                 @[@"Flights Climbed", @"flights_value", @"text"],
                 nil];
    
    // Create table
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _settings.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellID = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellID];
    }
    
    NSArray *setting = _settings[indexPath.row];
    NSString *title = setting[0];
    NSString *key = setting[1];
    NSString *type = setting[2];
    
    cell.textLabel.text = title;
    
    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        sw.tag = indexPath.row;
        cell.accessoryView = sw;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSArray *setting = _settings[sender.tag];
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:setting[1]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSArray *setting = _settings[indexPath.row];
    NSString *key = setting[1];
    NSString *type = setting[2];
    
    if ([type isEqualToString:@"text"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:setting[0]
                                                                       message:@"Enter value:"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.keyboardType = UIKeyboardTypeDecimalPad;
            textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:key];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *value = alert.textFields[0].text;
            [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];
            
            // Also save to config file
            [self saveConfig];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)saveConfig {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    BOOL enabled = [defaults boolForKey:@"healthboost_enabled"];
    NSString *stepsStr = [defaults stringForKey:@"steps_value"];
    NSString *distanceStr = [defaults stringForKey:@"distance_value"];
    NSString *flightsStr = [defaults stringForKey:@"flights_value"];
    
    double steps = [stepsStr doubleValue];
    double distance = [distanceStr doubleValue];
    double flights = [flightsStr doubleValue];
    
    NSDictionary *config = @{
        @"enabled": @(enabled),
        @"steps": @(steps),
        @"distance": @(distance),
        @"flights": @(flights)
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
    
    NSLog(@"Config saved: enabled=%@, steps=%.0f, distance=%.2f, flights=%.0f",
          @(enabled), steps, distance, flights);
}

@end
