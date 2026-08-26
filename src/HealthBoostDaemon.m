// HealthBoost - Apple Health Data Modifier (roothide deb)
// Simple daemon that writes health data using HealthKit
// Written: 2026-08-26

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

#define CONFIG_PATH @"/var/jb/Library/HealthBoost/config.plist"
#define LOG_PATH @"/var/jb/Library/HealthBoost/healthboost.log"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Create log directory
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:@"/var/jb/Library/HealthBoost"
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
        
        // Initialize HealthKit store
        HKHealthStore *store = [[HKHealthStore alloc] init];
        
        // Request authorization
        NSSet *typesToShare = [NSSet setWithObjects:
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed],
            nil];
        
        __block BOOL authDone = NO;
        __block BOOL authSuccess = NO;
        
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        [queue addOperationWithBlock:^{
            [store requestAuthorizationToShareTypes:typesToShare
                                         readTypes:typesToShare
                                completionHandler:^(BOOL success, NSError *error) {
                authSuccess = success;
                authDone = YES;
                if (!success) {
                    NSLog(@"HealthKit auth failed: %@", error.localizedDescription);
                }
            }];
            while (!authDone) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }];
        
        // Read config
        NSDictionary *config = nil;
        NSData *configData = [fm contentsAtPath:CONFIG_PATH];
        if (configData) {
            NSError *error = nil;
            config = [NSPropertyListSerialization propertyListWithData:configData
                                                              options:0
                                                               format:nil
                                                                error:&error];
        }
        
        if (!config) {
            config = @{ @"enabled": @NO, @"steps": @0, @"distance": @0.0, @"flights": @0 };
        }
        
        BOOL enabled = [[config[@"enabled"] stringValue] boolValue];
        if (!enabled) {
            NSLog(@"HealthBoost: disabled, exiting");
            return 0;
        }
        
        double steps = [[config[@"steps"] stringValue] doubleValue];
        double distance = [[config[@"distance"] stringValue] doubleValue];
        double flights = [[config[@"flights"] stringValue] doubleValue];
        
        NSLog(@"HealthBoost: enabled, steps=%.0f, distance=%.2f, flights=%.0f", steps, distance, flights);
        
        NSDate *now = [NSDate date];
        
        // Write steps
        if (steps > 0) {
            HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
            HKQuantity *quantity = [HKQuantity quantityWithType:stepType doubleValue:steps];
            HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:stepType
                                                                        quantity:quantity
                                                                       startDate:now
                                                                         endDate:[now dateByAddingTimeInterval:1]
                                                                        metadata:nil];
            __block BOOL stepDone = NO;
            [store saveObject:sample completionHandler:^(BOOL success, NSError *error) {
                stepDone = YES;
                if (success) {
                    NSLog(@"Wrote %.0f steps", steps);
                } else {
                    NSLog(@"Failed to write steps: %@", error.localizedDescription);
                }
            }];
            while (!stepDone) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }
        
        // Write distance
        if (distance > 0) {
            HKQuantityType *distType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
            HKQuantity *quantity = [HKQuantity quantityWithType:distType doubleValue:distance];
            HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:distType
                                                                        quantity:quantity
                                                                       startDate:now
                                                                         endDate:[now dateByAddingTimeInterval:1]
                                                                        metadata:nil];
            __block BOOL distDone = NO;
            [store saveObject:sample completionHandler:^(BOOL success, NSError *error) {
                distDone = YES;
                if (success) {
                    NSLog(@"Wrote %.2f meters", distance);
                } else {
                    NSLog(@"Failed to write distance: %@", error.localizedDescription);
                }
            }];
            while (!distDone) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }
        
        // Write flights
        if (flights > 0) {
            HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
            HKQuantity *quantity = [HKQuantity quantityWithType:flightType doubleValue:flights];
            HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:flightType
                                                                        quantity:quantity
                                                                       startDate:now
                                                                         endDate:[now dateByAddingTimeInterval:1]
                                                                        metadata:nil];
            __block BOOL flightDone = NO;
            [store saveObject:sample completionHandler:^(BOOL success, NSError *error) {
                flightDone = YES;
                if (success) {
                    NSLog(@"Wrote %.0f flights", flights);
                } else {
                    NSLog(@"Failed to write flights: %@", error.localizedDescription);
                }
            }];
            while (!flightDone) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }
        
        NSLog(@"HealthBoost completed");
    }
    return 0;
}
