// HealthBoost - 锁屏后台守护进程（roothide deb）
// 作用：在 iPhone 锁屏/睡眠状态下，按用户设定时间每日自动写入「真实+虚拟」步数。
//
// 设计要点（与 App 的 HealthBoostApp.m 保持一致，杜绝重复叠加）：
//   1) 只写【虚拟增量】样本：用 HBMakeDeviceSample 注入设备源 + HBSyntheticStepMetaKey 标记，
//      每次生成先删掉带标记的合成样本，再写一个，绝不碰真实步数。
//   2) 健康显示 = 真实步数 + 虚拟增量（healthd 自动把我们的设备源样本累加进当日总和）。
//   3) 微信显示：把「真实+虚拟」的目标值写进微信容器/共享文件，tweak 原样返回。
//   4) StartCalendarInterval 每 15 分钟唤起一次，内部判断是否已到计划时间且今日未生成，
//      因此即使锁屏也照常每日自动生成。

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#include <stdarg.h>

#define HBSyntheticStepMetaKey @"com.sykes.ucs.virtualStep"
#define CONFIG_PATH  @"/var/mobile/Media/HealthBoost/config.plist"
#define LOG_PATH    @"/var/mobile/Media/HealthBoost/daemon.log"
#define LASTGEN_PATH @"/var/mobile/Media/HealthBoost/lastgen.txt"

static void HBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [LOG_PATH stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    NSLog(@"[HealthBoostDaemon] %@", msg);
}

// 与 App 端完全一致的「设备源样本」构造：注入 _sourceRevision，让 healthd 当作 iPhone 设备数据。
static HKQuantitySample *HBMakeDeviceSample(HKQuantityType *type, HKQuantity *quantity, NSDate *start, NSDate *end) {
    HKDevice *device = [HKDevice localDevice];
    HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type
                                                              quantity:quantity
                                                           startDate:start
                                                             endDate:end
                                                               device:device
                                                           metadata:@{ HBSyntheticStepMetaKey : @YES }];
    return sample;
}

// ---- 微信步数文件通道（与 App 的 HBWriteStepsPreference 同款） ----
static NSString *HBFakeDateLine(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"date:%@", [f stringFromDate:[NSDate date]]];
}

static NSArray<NSString *> *HBWeChatContainerPaths(void) {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
    if (!dirs) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *d in dirs) {
        NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        if ([ident isEqualToString:@"com.tencent.xin"] ||
            [ident isEqualToString:@"UGGD"] ||
            [ident hasPrefix:@"com.tencent"]) {
            [out addObject:[base stringByAppendingPathComponent:d]];
        }
    }
    return out;
}

static void HBWriteStepsToWeChatContainers(long steps) {
    NSArray *containers = HBWeChatContainerPaths();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    for (NSString *c in containers) {
        NSString *doc = [c stringByAppendingPathComponent:@"Documents"];
        if (![fm fileExistsAtPath:doc]) [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
        if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];
        BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
        if (ok) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
    }
}

static void HBWriteStepsFile(long steps) {
    NSString *dir = @"/var/mobile/Media/HealthBoost";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void HBWriteStepsToVarMobileDocuments(long steps) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *doc = @"/var/mobile/Documents";
    if (![fm fileExistsAtPath:doc]) [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    if (ok) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
}

// 读真实步数（排除我们自己写的合成样本）
static long HBQueryRealTodaySteps(HKHealthStore *store) {
    __block long real = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSDate *startOfDay = [[NSCalendar currentCalendar] startOfDayForDate:now];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                      predicate:pred
                                                          limit:HKObjectQueryNoLimit
                                                sortDescriptors:nil
                                                 resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        for (HKSample *s in (results ?: @[])) {
            if (![s isKindOfClass:[HKQuantitySample class]]) continue;
            NSDictionary *md = ((HKQuantitySample *)s).metadata;
            if (md && [md[HBSyntheticStepMetaKey] boolValue]) continue;
            double v = [((HKQuantitySample *)s).quantity doubleValueForUnit:[HKUnit countUnit]];
            real += (long)(v + 0.5);
        }
        dispatch_semaphore_signal(sem);
    }];
    [store executeQuery:q];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return real;
}

// 删除今天所有带标记的合成样本（步数/距离/楼层），只动我们自己的，保留真实数据
static void HBDeleteSyntheticSamples(HKHealthStore *store) {
    NSDate *now = [NSDate date];
    NSDate *startOfDay = [[NSCalendar currentCalendar] startOfDayForDate:now];
    NSArray *types = @[[HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
                       [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
                       [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed]];
    NSMutableArray *toDelete = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    for (HKQuantityType *t in types) {
        NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:t
                                                          predicate:pred
                                                              limit:HKObjectQueryNoLimit
                                                    sortDescriptors:nil
                                                     resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
            for (HKSample *s in (results ?: @[])) {
                if (![s isKindOfClass:[HKQuantitySample class]]) continue;
                NSDictionary *md = ((HKQuantitySample *)s).metadata;
                if (md && [md[HBSyntheticStepMetaKey] boolValue]) [toDelete addObject:s];
            }
            dispatch_semaphore_signal(sem);
        }];
        [store executeQuery:q];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }
    for (HKSample *s in toDelete) {
        dispatch_semaphore_t dsem = dispatch_semaphore_create(0);
        [store deleteObject:s withCompletion:^(BOOL ok, NSError *e) {
            HBLog(@"删除虚拟增量 %@ ok=%d", s.sampleType.identifier, ok);
            dispatch_semaphore_signal(dsem);
        }];
        dispatch_semaphore_wait(dsem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }
    HBLog(@"已删除 %lu 条旧虚拟增量样本", (unsigned long)toDelete.count);
}

// 写一条合成增量样本（设备源）
static void HBWriteOneSample(HKHealthStore *store, HKQuantityType *type, double value, NSDate *when) {
    HKQuantity *q = [HKQuantity quantityWithUnit:[type isEqual:[HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning]] ? [HKUnit meterUnit] : [HKUnit countUnit] doubleValue:value];
    HKQuantitySample *sample = HBMakeDeviceSample(type, q, when, when);
    if (!sample) { HBLog(@"样本构造失败 %@", type.identifier); return; }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [store saveObject:sample withCompletion:^(BOOL success, NSError *error) {
        HBLog(@"写入 %@ = %.0f ok=%d %@", type.identifier, value, success, error ? error.localizedDescription : @"");
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
}

static NSString *HBTodayString(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        HBLog(@"==== HealthBoost 守护进程启动 ====");
        NSFileManager *fm = [NSFileManager defaultManager];

        // 读配置
        NSDictionary *config = nil;
        NSData *configData = [fm contentsAtPath:CONFIG_PATH];
        if (configData) config = [NSPropertyListSerialization propertyListWithData:configData options:0 format:nil error:nil];
        if (!config) { HBLog(@"无配置，退出"); return 0; }

        BOOL enabled = [config[@"enabled"] boolValue];
        if (!enabled) { HBLog(@"守护进程未启用，退出"); return 0; }

        long virtual  = [config[@"steps"] longValue];    if (virtual <= 0) virtual = 1000;
        double distance = [config[@"distance"] doubleValue]; if (distance <= 0) distance = virtual * 0.7;
        long flights  = [config[@"flights"] longValue];   if (flights <= 0) flights = 5;
        NSInteger cfgHour = [config[@"hour"] integerValue]; if (cfgHour < 0 || cfgHour > 23) cfgHour = 9;
        NSInteger cfgMinute = [config[@"minute"] integerValue]; if (cfgMinute < 0 || cfgMinute > 59) cfgMinute = 0;

        // 今日是否已生成
        NSString *today = HBTodayString();
        NSString *lastgen = [NSString stringWithContentsOfFile:LASTGEN_PATH encoding:NSUTF8StringEncoding error:nil];
        if (lastgen && [lastgen isEqualToString:today]) {
            HBLog(@"今日(%@)已生成，跳过", today);
            return 0;
        }

        // 是否到达计划时间窗口（15 分钟容差，兼容任意分钟，含 45 分以后）
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *nowc = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
        NSInteger nowMin = nowc.hour * 60 + nowc.minute;
        NSInteger cfgMin = cfgHour * 60 + cfgMinute;
        NSInteger diff = (nowMin - cfgMin + 1440) % 1440;
        if (diff > 15) {
            HBLog(@"未到计划时间(%02ld:%02ld)，当前 %02ld:%02ld，距窗口 %ld 分，跳过",
                  (long)cfgHour, (long)cfgMinute, (long)nowc.hour, (long)nowc.minute, (long)diff);
            return 0;
        }
        HBLog(@"到达计划时间窗口，开始生成（虚拟=%ld, 距离=%.0f, 楼层=%ld）", virtual, distance, flights);

        // 健康授权
        HKHealthStore *store = [[HKHealthStore alloc] init];
        NSSet *shareTypes = [NSSet setWithObjects:
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
            [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed], nil];
        __block BOOL authDone = NO, authOK = NO;
        [store requestAuthorizationToShareTypes:shareTypes readTypes:nil completion:^(BOOL success, NSError *error) {
            authOK = success; authDone = YES;
            if (!success) HBLog(@"健康授权失败: %@", error.localizedDescription);
        }];
        for (int i = 0; i < 100 && !authDone; i++) [NSThread sleepForTimeInterval:0.1];
        if (!authOK) { HBLog(@"未授权（请先在 App 内点一次「生成」授权），退出"); return 0; }

        // 真实步数 -> 目标值
        long realToday = HBQueryRealTodaySteps(store);
        long target = realToday + virtual;
        HBLog(@"真实步数=%ld, 目标(真实+虚拟)=%ld", realToday, target);

        // 健康：删旧合成 + 写新合成增量（真实步数不动）
        HBDeleteSyntheticSamples(store);
        NSDate *when = [NSDate date];
        HBWriteOneSample(store, [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount], (double)virtual, when);
        HBWriteOneSample(store, [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning], distance, when);
        HBWriteOneSample(store, [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed], (double)flights, when);

        // 微信：写目标值（真实+虚拟），tweak 原样返回
        HBWriteStepsToWeChatContainers(target);
        HBWriteStepsToVarMobileDocuments(target);
        HBWriteStepsFile(target);
        NSString *todayStr = HBFakeDateLine();
        CFPreferencesSetValue(CFSTR("steps"), (__bridge CFNumberRef)@(target),
                              CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("stepsDate"), (__bridge CFStringRef)[todayStr substringFromIndex:5],
                              CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        HBLog(@"微信步数文件已写为目标值 %ld", target);

        // 记录今日已生成
        [today writeToFile:LASTGEN_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        HBLog(@"==== 生成完成 ====");
    }
    return 0;
}
