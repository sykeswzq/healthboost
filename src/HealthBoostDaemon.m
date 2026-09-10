// HealthBoost - 后台守护进程（roothide 范式）
// 作用：锁屏/后台也能「每日自动生成」运动数据。
//   · 由 LaunchDaemon (StartCalendarInterval) 定时唤起，无视锁屏状态。
//   · 读 App 写入的共享配置 /var/mobile/Media/HealthBoost/config.plist
//     （roothide 下 App 与守护进程看到的是同一个重映射视图）。
//   · 写【设备源增量】样本（真实步数 + 虚拟增量），而不是绝对值覆盖，
//     与健康 App 中“真实+虚拟”的语义一致（V2.0 验证过的设备源写法）。
//   · 每次先删掉当天自己写的“合成”样本再写新的，幂等，不会逐次累加。
//
// 编译：build.sh 用 ldid -M -SHealthBoost.entitlements.plist 签名（含 healthkit 私有权限）。

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>

#define CONFIG_PATH @"/var/mobile/Media/HealthBoost/config.plist"
#define LOG_PATH    @"/var/mobile/Media/HealthBoost/daemon.log"
#define SYNTH_KEY   @"com.sykes.ucs.virtualStep"

static void HBLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[HealthBoostDaemon] %@", msg);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [LOG_PATH stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [[NSDate date] description], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 构造设备源样本：注入 _sourceRevision 让 healthd 当作 iPhone 设备数据，可靠叠加。
static HKQuantitySample *HBMakeDeviceSample(HKQuantityType *type,
                                            HKQuantity *qty,
                                            NSDate *start,
                                            NSDate *end,
                                            HKSourceRevision *devRev) {
    HKDevice *device = [HKDevice localDevice];
    HKQuantitySample *s = [HKQuantitySample quantitySampleWithType:type
                                                          quantity:qty
                                                       startDate:start
                                                         endDate:end
                                                           device:device
                                                       metadata:@{SYNTH_KEY: @YES}];
    if (!s) return nil;
    if (devRev) {
        @try {
            [s setValue:[devRev copy] forKey:@"_sourceRevision"];
        } @catch (NSException *e) {
            (void)e;
        }
    }
    return s;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        // 读 App 写入的共享配置
        NSDictionary *cfg = nil;
        NSData *d = [fm contentsAtPath:CONFIG_PATH];
        if (d) {
            cfg = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
        }
        if (!cfg) {
            HBLog(@"无配置，退出");
            return 0;
        }
        BOOL enabled = [cfg[@"enabled"] boolValue];
        if (!enabled) {
            HBLog(@"未启用（enabled=NO，通常是定时开关关闭），退出");
            return 0;
        }
        long steps = [cfg[@"steps"] longValue];
        double distance = [cfg[@"distance"] doubleValue];
        long flights = [cfg[@"flights"] longValue];
        NSInteger hour = [cfg[@"hour"] integerValue];
        NSInteger minute = [cfg[@"minute"] integerValue];
        if (steps <= 0) {
            HBLog(@"steps<=0，退出");
            return 0;
        }

        // 仅在到达计划时间后才生成（每天一次；幂等由“删旧合成样本”保证）
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *now = [NSDate date];
        NSDateComponents *hm = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:now];
        NSInteger curH = [hm hour];
        NSInteger curM = [hm minute];
        if (curH < hour || (curH == hour && curM < minute)) {
            HBLog(@"未到计划时间 (%02ld:%02ld < %02ld:%02ld)，跳过", (long)curH, (long)curM, (long)hour, (long)minute);
            return 0;
        }

        HKHealthStore *store = [[HKHealthStore alloc] init];
        NSSet *types = [NSSet setWithObjects:
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed],
            nil];
        // 尽力请求授权（ entitlements 含 healthkit 私有权限，设备源写入通常不受 app 级授权限制）
        [store requestAuthorizationToShareTypes:types
                                       readTypes:types
                                      completion:^(BOOL ok, NSError *e) {
            HBLog(@"授权回调 ok=%d %@", ok, e ? e.localizedDescription : @"");
        }];

        HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];

        // 取一个“设备源” HKSourceRevision（bid=nil 或 com.apple.health.*）
        __block HKSourceRevision *devRev = nil;
        NSDateComponents *back = [[NSDateComponents alloc] init];
        back.day = -7;
        NSDate *start7 = [cal dateByAddingComponents:back toDate:now options:0];
        NSPredicate *pred7 = [HKQuery predicateForSamplesWithStartDate:start7 endDate:now options:HKQueryOptionNone];
        dispatch_semaphore_t semRev = dispatch_semaphore_create(0);
        HKSampleQuery *qRev = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                              predicate:pred7
                                                                  limit:200
                                                        sortDescriptors:nil
                                                         resultsHandler:^(HKSampleQuery *q, NSArray *res, NSError *err) {
            if (err) HBLog(@"取设备源rev错误: %@", err);
            for (HKSample *s in res ?: @[]) {
                HKSourceRevision *r = s.sourceRevision;
                if (!r) continue;
                NSString *bid = r.source.bundleIdentifier;
                if (bid == nil || [bid hasPrefix:@"com.apple.health."]) { devRev = r; break; }
            }
            HBLog(@"设备源rev=%@", devRev ?: @"nil");
            dispatch_semaphore_signal(semRev);
        }];
        [store executeQuery:qRev];
        dispatch_semaphore_wait(semRev, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));

        NSDate *startOfDay = [cal startOfDayForDate:now];

        // 1) 删掉今天已有的“合成”样本（幂等，避免重复叠加）
        NSPredicate *todayPred = [HKQuery predicateForSamplesWithStartDate:startOfDay
                                                                   endDate:now
                                                                   options:HKQueryOptionNone];
        dispatch_semaphore_t semDel = dispatch_semaphore_create(0);
        HKSampleQuery *qDel = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                              predicate:todayPred
                                                                  limit:NSUIntegerMax
                                                        sortDescriptors:nil
                                                         resultsHandler:^(HKSampleQuery *q, NSArray *res, NSError *err) {
            NSMutableArray *old = [NSMutableArray array];
            for (HKSample *s in res ?: @[]) {
                if ([s.metadata[SYNTH_KEY] boolValue]) [old addObject:s];
            }
            HBLog(@"待删除旧合成样本=%lu", (unsigned long)old.count);
            if (old.count == 0) { dispatch_semaphore_signal(semDel); return; }
            [store deleteObjects:old withCompletion:^(BOOL success, NSError *e2) {
                HBLog(@"删除旧合成样本 ok=%d %@", success, e2 ? e2.localizedDescription : @"");
                dispatch_semaphore_signal(semDel);
            }];
        }];
        [store executeQuery:qDel];
        dispatch_semaphore_wait(semDel, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));

        // 2) 写新的“合成增量”样本（设备源，叠加到真实步数之上）
        NSMutableArray *samples = [NSMutableArray array];
        [samples addObject:HBMakeDeviceSample(stepType,
                                              [HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:(double)steps],
                                              startOfDay, now, devRev)];
        if (distance > 0) {
            [samples addObject:HBMakeDeviceSample(
                [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
                [HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:distance],
                startOfDay, now, devRev)];
        }
        if (flights > 0) {
            [samples addObject:HBMakeDeviceSample(
                [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed],
                [HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:(double)flights],
                startOfDay, now, devRev)];
        }

        dispatch_semaphore_t semSave = dispatch_semaphore_create(0);
        __block BOOL allOk = YES;
        __block NSUInteger done = 0;
        for (HKQuantitySample *sm in samples) {
            [store saveObject:sm withCompletion:^(BOOL success, NSError *e3) {
                HBLog(@"写入样本 ok=%d %@", success, e3 ? e3.localizedDescription : @"");
                if (!success) allOk = NO;
                done++;
                if (done >= samples.count) dispatch_semaphore_signal(semSave);
            }];
        }
        if (samples.count == 0) dispatch_semaphore_signal(semSave);
        dispatch_semaphore_wait(semSave, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));

        HBLog(@"完成：steps=%ld distance=%.1f flights=%ld allOk=%d", steps, distance, flights, allOk);
    }
    return 0;
}
