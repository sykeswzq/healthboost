// HealthBoost - iOS App that writes steps / distance / flights to Apple Health as device source

// ä½¿ç¨ com.apple.private.healthkit.source_override + authorization_bypass ç§ææé

// è®©ååºç step count æ¥æºä¼ªè£æ iPhone è®¾å¤æºï¼ä»èè¢«å¾®ä¿¡è¿å¨ç­åºç¨è¯»å

#import <UIKit/UIKit.h>

#import <Foundation/Foundation.h>

#import <HealthKit/HealthKit.h>

#import <objc/runtime.h>

#import <dlfcn.h>

#import <UserNotifications/UserNotifications.h>



// ååå£°æï¼HBDumpEntitlements å®ä¹å¨ HBLog ä¹åï¼éåå£°æå¦åä¼è§¦åéå¼å£°æéè¯¯

static void HBLog(NSString *fmt, ...);



static NSString * const HBSettingsKey = @"com.sykes.ucs.settings";



// MARK: - Logging helper

// æ¥å¿åæ¶åå°ä¸¤ä¸ªä½ç½®ï¼

//   1) /var/mobile/Media/HealthBoost/hb_log.txt  ââ Files Appãæç iPhoneãéè½ç´æ¥çå°

//   2) App æ²ç Documents/hb_log.txt              ââ ä¿åºï¼App åãæ¥çæ¥å¿ãè½è¯»

// App å¸¦ com.apple.private.security.no-sandboxï¼å¯åæ²çå¤è·¯å¾ã



// è¿½å ä¸è¡å°æå®è·¯å¾ï¼å¹¶èªå¨è£åªä¸ºæ»å¨æ¥å¿ï¼æå¤ä¿ç HB_MAX_LOG_LINES è¡ï¼

// é²æ­¢æ¥å¿æ éå¢é¿å¯¼è´ UIPasteboard å¤å¶å¤±è´¥ / å¼¹çªæªæ­ã

static const NSInteger HB_MAX_LOG_LINES = 200;



static void HBAppendLine(NSString *path, NSString *line) {

    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *dir = [path stringByDeletingLastPathComponent];

    if (![fm fileExistsAtPath:dir]) {

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    }



    // è¯»åæ§æ¥å¿

    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];

    NSMutableArray *lines = [NSMutableArray array];

    if (old.length > 0) {

        [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];

        // å»ææ«å°¾å¯è½å­å¨çç©ºè¡

        while (lines.count > 0 && [lines.lastObject length] == 0) {

            [lines removeLastObject];

        }

    }



    // è¿½å æ°è¡

    [lines addObject:line];



    // æ»å¨è£åªï¼ä¿çæå HB_MAX_LOG_LINES è¡

    while (lines.count > HB_MAX_LOG_LINES) {

        [lines removeObjectAtIndex:0];

    }



    // åå

    NSString *out = [lines componentsJoinedByString:@"\n"];

    if (lines.count > 0) out = [out stringByAppendingString:@"\n"];

    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

}



// å¤é¨å±äº«æ¥å¿è·¯å¾ï¼Files App å¯è§ï¼

static NSString *HBSharedLogPath(void) {

    return @"/var/mobile/Media/HealthBoost/hb_log.txt";

}



// API æ¢æµè¾åºè·¯å¾ï¼æ HealthKit ç¸å³ç±»çå¨é¨æ¹æ³ï¼å«ç§æï¼å¯¼åºå°è¿éï¼

// ç¨äºå®ä½çæ­£è½æ¹å sample æ¥æºçç§æåå§åå¨ / ä¿å­å¥å£ã

static NSString *HBAPIDumpPath(void) {

    return @"/var/mobile/Media/HealthBoost/api_dump.txt";

}



// æä¸¾æä¸ªç±»çææå®ä¾æ¹æ³ï¼å«ç§æï¼ï¼è¿½å å° out

static void HBDumpMethods(NSMutableString *out, Class cls, NSString *clsName, NSArray *keywords) {

    unsigned int count = 0;

    Method *methods = class_copyMethodList(cls, &count);

    for (unsigned int i = 0; i < count; i++) {

        SEL sel = method_getName(methods[i]);

        const char *name = sel_getName(sel);

        if (name == NULL) continue;

        NSString *sn = [NSString stringWithUTF8String:name];

        // è¥ç»äºå³é®å­ï¼åªè¾åºå½ä¸­çï¼å¦åå¨è¾åº

        BOOL hit = (keywords == nil);

        for (NSString *kw in keywords) {

            if ([sn rangeOfString:kw options:NSCaseInsensitiveSearch].length > 0) { hit = YES; break; }

        }

        if (hit) {

            // éå¸¦åæ°ä¸ªæ°ä¸æ¹æ³ç­¾åï¼ä¾¿äºå®å¨æé  NSInvocation

            unsigned int nargs = method_getNumberOfArguments(methods[i]);

            const char *types = method_getTypeEncoding(methods[i]);

            [out appendFormat:@"%@ : %@   [args=%u types=%s]\n",

             clsName, sn, nargs, types ? types : ""];

        }

    }

    free(methods);

}



// ææ­¥æ°åå°ãä¾å¾®ä¿¡ tweak è¯»åãçééã

// åééï¼v76 èµ·ï¼ï¼

//   1) æä»¶ /var/mobile/Media/HealthBoost/hb_steps.txt ââ çå®å±äº«è·¯å¾ï¼roothide ä¸æç¨³ï¼

//      å¾®ä¿¡è¿ç¨éç tweak ç´æ¥è¯»è¿ä¸ªæä»¶ãè¿æ¯ä¸»ééã

//   2) CFPreferences com.apple.mobile.healthboost ââ ååºã

// è¿ä¸æ­¥ä¸å HealthKit æ¯ä¸¤æ¡ç¬ç«é¾è·¯ï¼HealthKit ç®¡ãå¥åº·ãAppï¼è¿éç®¡ãå¾®ä¿¡è¿å¨ãã

// æ­¥æ°æä»¶ç»ä¸æ ¼å¼ï¼ç¬¬ä¸è¡æ°å­ï¼ç¬¬äºè¡ date:YYYY-MM-DDï¼v1.0.201 èµ·å¿å¸¦ï¼ã

// tweak ç«¯æ®æ­¤åãä»å¤©ãæ ¡éªï¼æ¨å¤©çæ®çå¼ä¸åè¢«å¾®ä¿¡è¯»èµ°ã

static NSString *HBFakeDateLine(void) {

    NSDateFormatter *f = [[NSDateFormatter alloc] init];

    f.dateFormat = @"yyyy-MM-dd";

    return [NSString stringWithFormat:@"date:%@", [f stringFromDate:[NSDate date]]];

}



static void HBWriteStepsFile(long steps) {

    NSString *dir = @"/var/mobile/Media/HealthBoost";

    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:dir]) {

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    }

    NSString *path = [dir stringByAppendingPathComponent:@"hb_steps.txt"];

    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];

    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    HBLog(@"[HealthBoost] å·²åå¥æ­¥æ°æä»¶ %ld (file=%d) @ %@", steps, ok, path);

}



// æ¾å°å¾®ä¿¡ç¸å³è¿ç¨çæ°æ®å®¹å¨è·¯å¾ã

// åçï¼å¾®ä¿¡æ¯ App Store åºç¨ï¼è·å¨æ²çéï¼**è¯»ä¸å°** /var/mobile/Media/ ä¸çæä»¶ã

// ä½æ¬ App å¸¦ no-sandbox æéï¼å¯ä»¥ç´æ¥ææ­¥æ°æä»¶åè¿å®ä»¬èªå·±çå®¹å¨ï¼

// åèªè¿ç¨å¯¹èªå·±å®¹å¨åçæä»¶æ¯å¿å®å¯è¯»ç ââ è¿æ¯ç»å¼æ²çæå¯é çééã

// iOS å¨æ¯ä¸ªæ°æ®å®¹å¨æ ¹ç®å½æ¾ .com.apple.mobile_container_manager.metadata.plistï¼

// éé¢ç MCMMetadataIdentifier å°±æ¯è¯¥å®¹å¨å¯¹åºç bundle idã

static NSArray<NSString *> *HBWeChatContainerPaths(void) {

    NSString *base = @"/var/mobile/Containers/Data/Application";

    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];

    if (!dirs) {

        HBLog(@"[HealthBoost] å®¹å¨æ«æå¤±è´¥: /var/mobile/Containers/Data/Application ä¸å¯è¯»");

        return @[];

    }

    NSMutableArray *out = [NSMutableArray array];

    for (NSString *d in dirs) {

        NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];

        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];

        NSString *ident = dict[@"MCMMetadataIdentifier"];

        // ä¸»å¾®ä¿¡ãæ­¥æ°è¿ç¨ UGGDï¼ä»¥åææå¾®ä¿¡æä»¶/æ©å±å®¹å¨é½è¦çï¼

        // é¿åå ä¸ºçéãå°åºåªä¸ªè¿ç¨å¨è¯»æ­¥æ°ãèæ¼æçæ­£çç®æ ã

        if ([ident isEqualToString:@"com.tencent.xin"] ||

            [ident isEqualToString:@"UGGD"] ||

            [ident hasPrefix:@"com.tencent"]) {

            [out addObject:[base stringByAppendingPathComponent:d]];

            HBLog(@"[HealthBoost] æ¾å°å¾®ä¿¡ç¸å³å®¹å¨: %@ -> %@", ident, d);

        }

    }

    return out;

}



// æ æ²ççå®æ¤è¿ç¨ï¼æ¯å¦ UGGDï¼å¯è½æ ¹æ¬æ²¡ææ°æ®å®¹å¨ï¼

// æ­¤æ¶å®çå¯åè½ç¹æ¯ /var/mobile/Documentsãè¿éä¸å¹¶åä¸ä»½ååºã

static NSInteger HBWriteStepsToVarMobileDocuments(long steps) {

    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *doc = @"/var/mobile/Documents";

    if (![fm fileExistsAtPath:doc]) {

        [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];

    }

    NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];

    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];

    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];

    if (ok) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];

    HBLog(@"[HealthBoost] åå¥ /var/mobile/Documents/hb_steps.txt (ok=%d) ââ ä¾æ å®¹å¨å®æ¤è¿ç¨è¯»å", ok);

    return ok ? 1 : 0;

}



// â¡d roothide ä¿®å¤ï¼ææ­¥æ°åå° UCS App èªèº«å®¹å¨ Documentsãroothide åºç¨çèªèº«å®¹å¨

// ç±ç³»ç»éæ å°å° /var/roothide/var/mobile/Containers/.../Documentsï¼ä¸ tweak ç«¯

// æä¸¾ com.sykes.ucs.app å®¹å¨è¯»åçè·¯å¾å®å¨ä¸è´ï¼æ¯æç¨³çè·¨è¿ç¨ééï¼ä¸ä¾èµ /var/mobile éæ å°ï¼ã

static NSInteger HBWriteStepsToOwnContainer(long steps) {

    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);

    NSString *doc = paths.firstObject;

    if (doc.length == 0) return 0;

    NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];

    // v2.2.6ï¼åä¹ååå æ§æä»¶ï¼æç ´ç¼å­ï¼ç¡®ä¿å¾®ä¿¡è½è¯»å°ææ°å¼
    if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];

    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];

    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];

    if (ok) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];

    HBLog(@"[HealthBoost] åå¥èªèº«å®¹å¨æ­¥æ°æä»¶ (ok=%d) @ %@", ok, path);

    return ok ? 1 : 0;

}



// ææ­¥æ°åè¿å¾®ä¿¡èªå·±çå®¹å¨ï¼æ²çåå¯è¯»ï¼ï¼è¿æ¯ v78 çä¸»ééã

static NSInteger HBWriteStepsToWeChatContainers(long steps) {

    NSArray *containers = HBWeChatContainerPaths();

    if (containers.count == 0) {

        HBLog(@"[HealthBoost] è­¦å: æªæ¾å°å¾®ä¿¡å®¹å¨ï¼æ­¥æ°æ æ³ä¼ ç»å¾®ä¿¡ï¼å¾®ä¿¡å¯è½æªå®è£ï¼");

        return 0;

    }

    NSFileManager *fm = [NSFileManager defaultManager];

    NSInteger okCount = 0;

    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];

    for (NSString *c in containers) {

        NSString *doc = [c stringByAppendingPathComponent:@"Documents"];

        if (![fm fileExistsAtPath:doc]) {

            [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];

        }

        NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];

        // v1.0.161ï¼åä¹ååå æ§æä»¶ï¼é¿åæ®çèå¼ï¼å¦æ©ææµè¯åä¸ç 99999ï¼è¦çä¸å½»åº

        if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];

        // ç¨ NSData åå¹¶è®¾ 0644ï¼ç¡®ä¿å¾®ä¿¡è¿ç¨ï¼mobile ç¨æ·ï¼å¯è¯»

        BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];

        if (ok) {

            [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];

            okCount++;

        }

        HBLog(@"[HealthBoost] åå¥å®¹å¨æ­¥æ° %ld -> %@ (ok=%d)", steps, path, ok);

    }

    return okCount;

}



static void HBWriteStepsPreference(long steps) {

    // v1.0.159ï¼è¯æ­å¢å¼ºââæ"å°åºåäºä»ä¹å¼å°åª"æå°åºæ¥ï¼å®ä½ 99999 æ¥æº

    HBLog(@"[HealthBoost] >> å³å°åå¥æ­¥æ°å¼ steps=%ld", steps);

    // éé1ï¼æå¯é ï¼ï¼åè¿å¾®ä¿¡ç¸å³å®¹å¨ï¼æ²çåå¿å®å¯è¯»

    NSInteger nContainers = HBWriteStepsToWeChatContainers(steps);

    // éé1bï¼æ å®¹å¨å®æ¤è¿ç¨ï¼UGGDï¼çååºè½ç¹

    NSInteger nVarMobile = HBWriteStepsToVarMobileDocuments(steps);

    // éé1cï¼roothide ä¿®å¤ ââ åè¿ UCS App èªèº«å®¹å¨ï¼ä¸ tweak â¡c è¯»åå¯¹åºï¼

    NSInteger nOwn = HBWriteStepsToOwnContainer(steps);

    // éé2ï¼å±äº« Media ç®å½ï¼ä»å¯¹æ æ²çè¿ç¨ææï¼

    HBWriteStepsFile(steps);

    // éé3ï¼CFPreferences ç³»ç»åï¼UCStep åæ¬¾è·¨æ²çææ³ï¼+ stepsDate ä¾ tweak æ ¡éªãä»å¤©ã

    NSString *todayStr = HBFakeDateLine();   // å½¢å¦ date:2026-09-04

    CFPreferencesSetValue(CFSTR("steps"),

                          (__bridge CFNumberRef)@(steps),

                          CFSTR("com.apple.mobile.healthboost"),

                          kCFPreferencesAnyUser,

                          kCFPreferencesAnyHost);

    CFPreferencesSetValue(CFSTR("stepsDate"),

                          (__bridge CFStringRef)[todayStr substringFromIndex:5],

                          CFSTR("com.apple.mobile.healthboost"),

                          kCFPreferencesAnyUser,

                          kCFPreferencesAnyHost);

    BOOL ok = CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"),

                                       kCFPreferencesAnyUser,

                                       kCFPreferencesAnyHost);

    HBLog(@"[HealthBoost] æ­¥æ°ééåå¥å®æ: å®¹å¨=%ld èªèº«å®¹å¨=%ld varMobile=%ld Media=1 åå¥½sync=%d åå¥å¼=%ld",

          (long)nContainers, (long)nOwn, (long)nVarMobile, ok, steps);

}



// æ¸é¤ææãä¾å¾®ä¿¡è¯»åãçæ­¥æ°åæ°æ®ï¼è®©å¾®ä¿¡æ¢å¤è¯»åçå®æ­¥æ°ã

// å¨ç¨æ·å³é­ãæ¯æ¥èªå¨çæãæ¶è°ç¨ï¼æ¢ç¶ä¸åèªå¨çæï¼å°±ä¸åºç»§ç»­ä¼ªé ã

static void HBClearStepsFiles(void) {

    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *containers = HBWeChatContainerPaths();

    for (NSString *c in containers) {

        NSString *path = [c stringByAppendingPathComponent:@"Documents/hb_steps.txt"];

        if ([fm fileExistsAtPath:path]) {

            [fm removeItemAtPath:path error:nil];

            HBLog(@"[HealthBoost] å·²æ¸é¤å®¹å¨æ­¥æ°æä»¶: %@", path);

        }

    }

    NSString *varDoc = @"/var/mobile/Documents/hb_steps.txt";

    if ([fm fileExistsAtPath:varDoc]) { [fm removeItemAtPath:varDoc error:nil]; HBLog(@"[HealthBoost] å·²æ¸é¤ /var/mobile/Documents/hb_steps.txt"); }

    NSString *media = @"/var/mobile/Media/HealthBoost/hb_steps.txt";

    if ([fm fileExistsAtPath:media]) { [fm removeItemAtPath:media error:nil]; HBLog(@"[HealthBoost] å·²æ¸é¤ /var/mobile/Media/HealthBoost/hb_steps.txt"); }

    CFPreferencesSetValue(CFSTR("steps"), NULL, CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    CFPreferencesSetValue(CFSTR("stepsDate"), NULL, CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    HBLog(@"[HealthBoost] å·²æ¸ç©º CFPreferences æ­¥æ°ï¼å¾®ä¿¡æ¢å¤çå®æ­¥æ°");

}



// æ«ææææ°æ®å®¹å¨ï¼æ¶é tweak åä¸çè¯æ­æ¥å¿ã

// tweak è·å¨å¾®ä¿¡æ²çéï¼åä¸äº /var/mobile/Media/ï¼åªè½åèªå·±å®¹å¨ç Documentsã

// æ¬ App æ æ²çï¼å¯ä»¥éåææå®¹å¨æå®è¯»åæ¥ã

static NSString *HBCollectTweakLogs(void) {

    NSMutableString *out = [NSMutableString string];

    NSFileManager *fm = [NSFileManager defaultManager];



    // 1) å±äº«ä½ç½®ï¼è¥ tweak æå¨è¿ç¨æ æ²çï¼æ¥å¿ä¼å¨è¿éï¼

    NSString *shared = [NSString stringWithContentsOfFile:@"/var/mobile/Media/HealthBoost/tweak_log.txt"

                                                encoding:NSUTF8StringEncoding error:nil];

    if (shared.length > 0) {

        [out appendString:@"--- /var/mobile/Media/HealthBoost/tweak_log.txt ---\n"];

        [out appendString:shared];

        [out appendString:@"\n"];

    }



    // 2) éåæææ°æ®å®¹å¨ç Documents/hb_tweak_log.txt

    NSString *base = @"/var/mobile/Containers/Data/Application";

    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];

    NSInteger found = 0;

    for (NSString *d in dirs) {

        NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];

        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];

        NSString *ident = dict[@"MCMMetadataIdentifier"] ?: @"(unknown)";



        NSString *logPath = [base stringByAppendingFormat:@"/%@/Documents/hb_tweak_log.txt", d];

        NSString *c = [NSString stringWithContentsOfFile:logPath

                                              encoding:NSUTF8StringEncoding error:nil];

        if (c.length > 0) {

            found++;

            [out appendFormat:@"--- å®¹å¨æ¥å¿ [%@] ---\n%@\n", ident, c];

        }

    }



    if (out.length == 0) {

        return @"ï¼æªæ¾å°ä»»ä½ tweak æ¥å¿ï¼\n"

               @"å¯è½åå ï¼\n"

               @"  1. tweak æªè¢«æ³¨å¥ ââ è£å® deb åå¿é¡»å½»åºææå¾®ä¿¡åéå¼ï¼\n"

               @"  2. å¾®ä¿¡/UGGD è¿ç¨è¿æ²¡éå¯è¿ï¼\n"

               @"  3. æ³¨å¥å¨ï¼ElleKit/Substrateï¼æªå è½½æ¬ tweakã\n";

    }

    if (found == 0 && shared.length > 0) found = 1;

    return out;

}



// è¯»åèªèº« entitlements çå®éçæå¼

// ç®çï¼ç¡®è®¤ ldid ç­¾ç com.apple.private.healthkit.source_override å°åºææ²¡æè¢«ç³»ç»è®¤å¯ã

// æ³¨æï¼SecTask ç³»åå¨ iOS SDK ä¸­æ²¡æå¬å¼å¤´æä»¶ï¼å± macOS ç§æ APIï¼ï¼

// è¿éç¨ dlsym è¿è¡æ¶æ¥æ¾ï¼æ¾ä¸å°å°±è·³è¿ï¼é¿åç¼è¯/é¾æ¥å¤±è´¥æè¿è¡æ¶å´©æºã

static void HBDumpEntitlements(void) {

    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);

    if (!sec) {

        HBLog(@"[HealthBoost] ENT: Security.framework å è½½å¤±è´¥");

        return;

    }



    typedef struct __SecTask *HBSecTaskRef;

    HBSecTaskRef (*hbSecTaskCreateFromSelf)(CFAllocatorRef) =

        (HBSecTaskRef (*)(CFAllocatorRef))dlsym(sec, "SecTaskCreateFromSelf");

    CFTypeRef (*hbSecTaskCopyValueForEntitlement)(HBSecTaskRef, CFStringRef, CFErrorRef *) =

        (CFTypeRef (*)(HBSecTaskRef, CFStringRef, CFErrorRef *))dlsym(sec, "SecTaskCopyValueForEntitlement");



    if (!hbSecTaskCreateFromSelf || !hbSecTaskCopyValueForEntitlement) {

        HBLog(@"[HealthBoost] ENT: SecTask ç¬¦å·ä¸å¯ç¨ï¼iOS æªå¯¼åºï¼ï¼è·³è¿æ£æ¥");

        return;

    }



    HBSecTaskRef task = hbSecTaskCreateFromSelf(kCFAllocatorDefault);

    if (!task) {

        HBLog(@"[HealthBoost] ENT: SecTaskCreateFromSelf è¿å NULL");

        return;

    }



    NSArray *keys = @[

        @"com.apple.private.healthkit.source_override",

        @"com.apple.private.healthkit.authorization_bypass",

        @"com.apple.private.healthkit.write_authorization_override",

        @"com.apple.private.security.storage.Health",

        @"com.apple.developer.healthkit",

        @"application-identifier",

    ];

    for (NSString *k in keys) {

        CFTypeRef v = hbSecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)k, NULL);

        if (v) {

            HBLog(@"[HealthBoost] ENT %@ = %@", k, (__bridge id)v);

            CFRelease(v);

        } else {

            HBLog(@"[HealthBoost] ENT %@ = (nil æªçæ)", k);

        }

    }

    CFRelease(task);

}



// å¯¼åº API æ¸åå°å±äº«ç®å½ï¼ä¸åæ¥å¿è¡æ°éå¶ï¼

static void HBDumpHealthKitAPIs(void) {

    NSMutableString *out = [NSMutableString string];

    [out appendString:@"=== HealthKit ç§æ API æ¢æµ ===\n\n"];



    // åªå³å¿ä¸ãæ¥æº / åå§å / ä¿å­ãç¸å³çæ¹æ³ï¼é¿åæä»¶è¿å¤§

    NSArray *kws = @[@"init", @"source", @"save", @"revision", @"device", @"insert", @"add", @"origin"];



    [out appendString:@"--- HKQuantitySample ---\n"];

    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", kws);



    [out appendString:@"\n--- HKSample ---\n"];

    HBDumpMethods(out, [HKSample class], @"HKSample", kws);



    [out appendString:@"\n--- HKSourceRevision ---\n"];

    HBDumpMethods(out, [HKSourceRevision class], @"HKSourceRevision", nil);



    [out appendString:@"\n--- HKSource ---\n"];

    HBDumpMethods(out, [HKSource class], @"HKSource", nil);



    [out appendString:@"\n--- HKHealthStore (save/delete ç¸å³) ---\n"];

    HBDumpMethods(out, [HKHealthStore class], @"HKHealthStore", @[@"save", @"delete", @"insert", @"add"]);



    [out appendString:@"\n--- HKQuantitySample å¨é¨æ¹æ³ ---\n"];

    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", nil);



    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *dir = [HBAPIDumpPath() stringByDeletingLastPathComponent];

    if (![fm fileExistsAtPath:dir]) {

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    }

    [out writeToFile:HBAPIDumpPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];

}



// æ²çåæ¥å¿è·¯å¾ï¼ä¿åºï¼

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

    // KVC æ³¨å¥ç§æ ivar _sourceRevisionï¼è®© healthd æ¥åè®¾å¤æº

    if (deviceSourceRev) {

        @try {

            [sample setValue:[deviceSourceRev copy] forKey:@"_sourceRevision"];

        } @catch (NSException *e) {

            (void)e;

            // åéï¼ä¸æ³¨å¥ sourceRevision

        }

    }

    return sample;

}



// MARK: - Main View Controller (UCSï¼ä»æ¥æ°æ® / æä½ / å®æ¶çæ)



@interface HBMainViewController : UITableViewController <UNUserNotificationCenterDelegate>

@property (assign, nonatomic) long steps;

@property (assign, nonatomic) long flights;

@property (assign, nonatomic) double ratio;        // æ­¥è·ç³»æ° 0.5~0.8ï¼ç¨äºæ¨ç®è·ç¦»

@property (assign, nonatomic) BOOL enabled;

@property (assign, nonatomic) BOOL scheduleOn;

@property (assign, nonatomic) NSInteger schedHour;

@property (assign, nonatomic) NSInteger schedMinute;

@property (assign, nonatomic) BOOL busy;

@property (strong, nonatomic) HKHealthStore *healthStore;

@property (assign, nonatomic) BOOL appWasActiveWhenStarted;

@property (strong, nonatomic) UILabel *statusLabel;

@property (strong, nonatomic) UIDatePicker *timePicker;

@end



@implementation HBMainViewController



- (instancetype)init {

    self = [super initWithStyle:UITableViewStyleInsetGrouped];

    return self;

}



- (void)viewDidLoad {

    [super viewDidLoad];

    self.title = @"UCS";

    self.view.backgroundColor = [UIColor systemBackgroundColor];



    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 48)];

    self.statusLabel.textAlignment = NSTextAlignmentCenter;

    self.statusLabel.font = [UIFont systemFontOfSize:13];

    self.statusLabel.textColor = [UIColor secondaryLabelColor];

    self.statusLabel.numberOfLines = 0;

    self.tableView.tableFooterView = self.statusLabel;

    // v2.2.14ï¼æ è®°Appå¯å¨æ¶å¤äºåå°ç¶æï¼ä½¿éç¥ç¹å»å¯è§¦åçæ
    self.appWasActiveWhenStarted = YES;


    [self loadSettings];

    [self setupNotifications];

    if (self.scheduleOn) [self scheduleDailyNotification];

    HBLog(@"[UCS] App å¯å¨");

}

- (void)applicationWillResignActive:(UIApplication *)application {
    // åºç¨å³å°è¿å¥åå°/éå±ï¼éç½® busyï¼é²æ­¢åå°å¼æ­¥åè°è®¿é®å·²éæ¾ç self
    self.busy = NO;
    self.appWasActiveWhenStarted = NO;
    HBLog(@"[UCS] applicationWillResignActive: éç½® busy");
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // åºç¨åå°åå°ï¼å·æ°è®¾ç½®ï¼æ è®°åå°ç¶æï¼æ£æ¥æ¯å¦éè¦è¡¥çæ
    self.appWasActiveWhenStarted = YES;
    [self loadSettings];
    if (self.scheduleOn) {
        NSString *today = HBTodayString();
        NSString *lastGen = [NSString stringWithContentsOfFile:HBLastGenPath() encoding:NSUTF8StringEncoding error:nil];
        if (lastGen.length == 0 || ![lastGen isEqualToString:today]) {
            // ä»å¤©è¿æ²¡çæè¿ï¼ä¸æ¶é´å·²è¿
            NSDate *now = [NSDate date];
            NSDateComponents *comps = [[NSCalendar currentCalendar] components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:now];
            if (comps.hour > self.schedHour || (comps.hour == self.schedHour && comps.minute >= self.schedMinute)) {
                // æ¶é´å·²è¿ï¼éè¦è¡¥çæ
                HBLog(@"[UCS] åå°åå°åç°ä»å¤©æªçæï¼è§¦åè¡¥çæ");
                [self generateNow];
            }
        }
    }
}




// æåçææ¥æè®°å½ï¼App æ²ç Documents/hb_lastgen.txtï¼åå®¹ä¸º YYYY-MM-DDï¼

static NSString *HBLastGenPath(void) {

    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

    return [doc stringByAppendingPathComponent:@"hb_lastgen.txt"];

}



static NSString *HBTodayString(void) {

    NSDateFormatter *f = [[NSDateFormatter alloc] init];

    f.dateFormat = @"yyyy-MM-dd";

    return [f stringFromDate:[NSDate date]];

}



// v1.0.205 ä¿®å¤ãæ¯æ¬¡æå¼é½å¼¹æææ¡ãï¼

// é®é¢æ ¹å ï¼æ¯æ¬¡å¯å¨é½è°ç¨ requestAuthorizationï¼ç³»ç»éå¤å¼¹çªã

// ä¿®å¤æ¹æ¡ï¼ç¨æä»¶æä¹åæ è®°ï¼è·¨éå¯ä¿çï¼ï¼ä»é¦æ¬¡è¯·æ±ææã

static NSString * const HBNotifFailCountKey = @"hb_notif_fail_count";

static NSString * const HBNotifFlagFile = @"/var/mobile/Documents/.hb_notif_requested";



// æ£æ¥æ¯å¦å·²è¯·æ±è¿éç¥æéï¼æä»¶æä¹åï¼æ¯NSUserDefaultsæ´å¯é ï¼

static BOOL HBHasRequestedNotification(void) {

    NSFileManager *fm = [NSFileManager defaultManager];

    // åæ¥æä»¶ï¼æå¯é ï¼

    if ([fm fileExistsAtPath:HBNotifFlagFile]) return YES;

    // åæ¥UserDefaultsï¼è¾å©ï¼

    BOOL defaultsVal = [[NSUserDefaults standardUserDefaults] boolForKey:HBNotifRequestedKey];

    return defaultsVal;

}



// æ è®°å·²è¯·æ±éç¥æéï¼åæä»¶ + UserDefaultsåéä¿éï¼

static void HBMarkNotificationRequested(void) {

    NSFileManager *fm = [NSFileManager defaultManager];

    // åæ è®°æä»¶å°ç¨æ·Documentsï¼roothideä¸å¯åï¼

    [fm createFileAtPath:HBNotifFlagFile contents:nil attributes:nil];

    // åæ­¥UserDefaults

    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:HBNotifRequestedKey];

    [[NSUserDefaults standardUserDefaults] synchronize];

}



static NSString * const HBNotifRequestedKey = @"hb_notif_requested";

- (void)setupNotifications {

    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];

    c.delegate = self;

    

    // æ£æ¥æ¯å¦å·²ç»è¯·æ±è¿ææï¼æä»¶æä¹åï¼è·¨éå¯ä¿çï¼

    if (HBHasRequestedNotification()) {

        HBLog(@"[UCS] éç¥æéå·²è¯·æ±è¿ï¼è·³è¿å¼¹çª");

        return;

    }

    

    // ç´æ¥è¯·æ±ææ

    [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge

                    completionHandler:^(BOOL g, NSError *e){

        // æ è®°å·²è¯·æ±ï¼æ è®ºæåå¤±è´¥ï¼

        HBMarkNotificationRequested();

        

        if (g) {

            HBLog(@"[UCS] éç¥æææå");

            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:HBNotifFailCountKey];

            [[NSUserDefaults standardUserDefaults] synchronize];

        } else {

            NSInteger failCount = [[NSUserDefaults standardUserDefaults] integerForKey:HBNotifFailCountKey] + 1;

            [[NSUserDefaults standardUserDefaults] setInteger:failCount forKey:HBNotifFailCountKey];

            [[NSUserDefaults standardUserDefaults] synchronize];

            HBLog(@"[UCS] éç¥ææå¤±è´¥ attempt=%ld err=%@", (long)failCount, e ? e.localizedDescription : @"nil");

            // å¤±è´¥è¶è¿3æ¬¡ï¼éé»è·³è¿

            if (failCount >= 3) {

                HBLog(@"[UCS] éç¥ææè¿ç»­å¤±è´¥3æ¬¡ï¼åç»­å¯å¨ä¸åè¯·æ±");

            }

        }

    }];

}



#pragma mark - Table



- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }



- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {

    if (s == 0) return @"ä»æ¥æ°æ®";

    if (s == 1) return @"æä½";

    return @"å®æ¶çæ";

}



- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {

    if (s == 0) return 3;

    if (s == 1) return 1;

    // å®æ¶çæsectionï¼çææ¶é´ + è®¾ç½®æ¶é´

    return 2;

}



- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell"];

    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];

    cell.accessoryView = nil;

    cell.accessoryType = UITableViewCellAccessoryNone;

    cell.textLabel.textColor = [UIColor labelColor];

    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    cell.imageView.tintColor = [UIColor systemOrangeColor];



    if (ip.section == 0) {

        if (ip.row == 0) {

            cell.imageView.image = [UIImage systemImageNamed:@"figure.walk"];

            cell.textLabel.text = @"æ­¥æ°";

            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld æ­¥", self.steps];

            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        } else if (ip.row == 1) {

            cell.imageView.image = [UIImage systemImageNamed:@"ruler"];

            cell.textLabel.text = @"è·ç¦»";

            double km = self.steps * self.ratio / 1000.0;

            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3f å¬é", km];

            cell.selectionStyle = UITableViewCellSelectionStyleNone;

        } else {

            cell.imageView.image = [UIImage systemImageNamed:@"stairs"];

            cell.textLabel.text = @"æ¥¼å±";

            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld å±", self.flights];

            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        }

    } else if (ip.section == 1) {

        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];

        cell.imageView.tintColor = [UIColor systemGreenColor];

        cell.textLabel.text = @"çæè¿å¨æ°æ®";

        cell.textLabel.textColor = [UIColor systemBlueColor];

        cell.detailTextLabel.text = nil;

    } else {

        if (ip.row == 0) {

            cell.imageView.image = [UIImage systemImageNamed:@"clock"];

            cell.textLabel.text = @"æ¯æ¥èªå¨çæ";

            cell.detailTextLabel.text = nil;

            UISwitch *sw = [[UISwitch alloc] init];

            sw.on = self.scheduleOn;

            [sw addTarget:self action:@selector(scheduleSwitchChanged:) forControlEvents:UIControlEventValueChanged];

            cell.accessoryView = sw;

            cell.selectionStyle = UITableViewCellSelectionStyleNone;

        } else if (ip.row == 1) {

            cell.imageView.image = [UIImage systemImageNamed:@"timer"];

            cell.textLabel.text = @"çææ¶é´";

            cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)self.schedHour, (long)self.schedMinute];

            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        }

    }

    return cell;

}



- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {

    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0 && ip.row == 0) {

        [self editIntegerWithTitle:@"æ­¥æ°" message:@"è®¾ç½®èææ­¥æ°ï¼å¨çå®æ­¥æ°ä¸ç´¯å ï¼" current:self.steps handler:^(long v){

            self.steps = v;

            [self saveSettings];

            // æ°é»è¾ï¼çå®æ­¥æ°+èææ­¥æ°ï¼ï¼ä¿å­å³åå¥ææééï¼

            // å¾®ä¿¡ä¾§ tweak è¯»å°çæ¯ãèææ­¥æ°å¢éãï¼æ¾ç¤º = çå®æ­¥æ° + è¯¥å¢éã

            HBWriteStepsPreference(v);

            [self writeVirtualStepSample:v];

            [self updateStatus:[NSString stringWithFormat:@"å·²çæï¼èææ­¥æ°å¢é %ldï¼å¾®ä¿¡æ¾ç¤º = çå® + %ldï¼å¥åº·=çå®+èæï¼", v, v]];

            [self.tableView reloadData];

        }];

    } else if (ip.section == 0 && ip.row == 2) {

        [self editIntegerWithTitle:@"æ¥¼å±" message:@"è®¾ç½®ç¬æ¥¼å±æ°" current:self.flights handler:^(long v){ self.flights = v; [self saveSettings]; [self.tableView reloadData]; }];

    } else if (ip.section == 1) {

        [self generateNow];

    } else if (ip.section == 2 && ip.row == 1) {

        [self pickTime];

    }

}



- (void)editIntegerWithTitle:(NSString *)title message:(NSString *)message current:(long)current handler:(void(^)(long))handler {

    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){

        tf.keyboardType = UIKeyboardTypeNumberPad;

        tf.text = [NSString stringWithFormat:@"%ld", current];

    }];

    [a addAction:[UIAlertAction actionWithTitle:@"åæ¶" style:UIAlertActionStyleCancel handler:nil]];

    [a addAction:[UIAlertAction actionWithTitle:@"ç¡®å®" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){

        long v = [a.textFields.firstObject.text integerValue];

        if (v < 0) v = 0;

        handler(v);

    }]];

    [self presentViewController:a animated:YES completion:nil];

}



// ç³»ç»åçæ¶é´éæ©å¨ï¼æ¨¡æ UINavigationController åæ¾ UIDatePicker(.wheels) + å®æ/åæ¶ã

// æ§çç¨ ActionSheet + æåçº¦æï¼å¸å±éä¹±å¯¼è´ãç¡®å®ãç¹ä¸å¨ï¼åçå¯¼èªæ æé®æç¨³ã

- (void)pickTime {

    UIViewController *pickerVC = [[UIViewController alloc] init];

    pickerVC.view.backgroundColor = [UIColor systemBackgroundColor];

    pickerVC.title = @"éæ©çææ¶é´";



    UIDatePicker *p = [[UIDatePicker alloc] init];

    p.datePickerMode = UIDatePickerModeTime;

    p.preferredDatePickerStyle = UIDatePickerStyleWheels;

    p.translatesAutoresizingMaskIntoConstraints = NO;

    NSCalendar *cal = [NSCalendar currentCalendar];

    NSDateComponents *c = [[NSDateComponents alloc] init];

    c.hour = self.schedHour; c.minute = self.schedMinute;

    p.date = [cal dateFromComponents:c] ?: [NSDate date];

    [pickerVC.view addSubview:p];

    self.timePicker = p;

    [NSLayoutConstraint activateConstraints:@[

        [p.leadingAnchor constraintEqualToAnchor:pickerVC.view.leadingAnchor],

        [p.trailingAnchor constraintEqualToAnchor:pickerVC.view.trailingAnchor],

        [p.centerYAnchor constraintEqualToAnchor:pickerVC.view.centerYAnchor],

        [p.heightAnchor constraintEqualToConstant:216]

    ]];



    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"å®æ"

                                                            style:UIBarButtonItemStyleDone

                                                           target:self

                                                           action:@selector(pickTimeDone:)];

    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"åæ¶"

                                                              style:UIBarButtonItemStylePlain

                                                             target:self

                                                             action:@selector(dismissPicker)];

    pickerVC.navigationItem.rightBarButtonItem = done;

    pickerVC.navigationItem.leftBarButtonItem = cancel;



    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pickerVC];

    nav.modalPresentationStyle = UIModalPresentationFormSheet;

    [self presentViewController:nav animated:YES completion:nil];

}



- (void)pickTimeDone:(id)sender {

    UIDatePicker *p = self.timePicker;

    if (p) {

        NSCalendar *c2 = [NSCalendar currentCalendar];

        NSDateComponents *cc = [c2 components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:p.date];

        self.schedHour = cc.hour; self.schedMinute = cc.minute;

        [self saveSettings];

        [self scheduleDailyNotification];

        [self.tableView reloadData];

        [self updateStatus:[NSString stringWithFormat:@"å·²è®¾ç½®æ¯æ¥ %02ld:%02ld çæ", (long)self.schedHour, (long)self.schedMinute]];

    }

    [self dismissViewControllerAnimated:YES completion:nil];

}



- (void)dismissPicker {

    [self dismissViewControllerAnimated:YES completion:nil];

}



- (void)scheduleSwitchChanged:(UISwitch *)sender {

    self.scheduleOn = sender.isOn;

    [self saveSettings];

    if (self.scheduleOn) [self scheduleDailyNotification];

    else {

        [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"UCSDailyGen"]];

        HBClearStepsFiles();   // å³é­å®æ¶ï¼æ¸æå¾®ä¿¡çåæ­¥æ°ï¼æ¢å¤çå®

    }

    [self updateStatus:self.scheduleOn ? [NSString stringWithFormat:@"å·²å¼å¯æ¯æ¥ %02ld:%02ld å®æ¶çæ", (long)self.schedHour, (long)self.schedMinute] : @"å·²å³é­å®æ¶"];

}



- (void)scheduleDailyNotification {

    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];

    [c removePendingNotificationRequestsWithIdentifiers:@[@"UCSDailyGen"]];

    if (!self.scheduleOn) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];

    content.title = @"UCS";

    content.body = @"æ­£å¨çæä»æ¥è¿å¨æ°æ®â¦";

    NSDateComponents *trig = [[NSDateComponents alloc] init];

    trig.hour = self.schedHour; trig.minute = self.schedMinute;

    UNCalendarNotificationTrigger *t = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:trig repeats:YES];

    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"UCSDailyGen" content:content trigger:t];

    [c addNotificationRequest:req withCompletionHandler:nil];

}



#pragma mark - UNUserNotificationCenterDelegate



- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // willPresentNotification: å¨ App å¤äºåå°/éå±æ¶è¢«ç³»ç»è°ç¨
    // æ­¤æ¶ä¸åºèªå¨è§¦åçæï¼é¿åãæªç¹æé®èªå¨çæãï¼
    if ([notification.request.identifier isEqualToString:@"UCSDailyGen"]) {
        HBLog(@"[UCS] willPresentNotification: æ¶å°å®æ¶éç¥ä½ App å¨åå°ï¼è·³è¿èªå¨çæ");
    }
    completionHandler(UNNotificationPresentationOptionNone);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void(^)(void))completionHandler {
    if ([response.notification.request.identifier isEqualToString:@"UCSDailyGen"]) {
        // didReceiveNotificationResponse: ç¨æ·å¨éç¥ä¸ç¹å»æ¶è§¦å
        // æ£æ¥ App æ¯å¦ä¹åå¨åå°è¿è¡è¿ï¼ç± appWasActiveWhenStarted æ è®°ï¼
        if (self.appWasActiveWhenStarted) {
            [self loadSettings];
            [self generateNow];
        } else {
            HBLog(@"[UCS] didReceiveNotificationResponse: App éåå°ç¶æï¼è·³è¿èªå¨çæ");
        }
    }
    completionHandler();
}



#pragma mark - Settings



- (void)loadSettings {

    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:HBSettingsKey];

    if (!d) d = @{@"enabled":@YES, @"steps":@1000, @"ratio":@0.7, @"flights":@5, @"scheduleOn":@NO, @"hour":@9, @"minute":@0};

    self.enabled = [d[@"enabled"] boolValue];

    self.steps = [d[@"steps"] longValue]; if (self.steps <= 0) self.steps = 1000;

    self.ratio = [d[@"ratio"] doubleValue]; if (self.ratio<0.5) self.ratio=0.5; if (self.ratio>0.8) self.ratio=0.8;

    self.flights = [d[@"flights"] longValue]; if (self.flights <= 0) self.flights = 5;

    self.scheduleOn = [d[@"scheduleOn"] boolValue];

    self.schedHour = [d[@"hour"] integerValue]; if (self.schedHour<0||self.schedHour>23) self.schedHour=9;

    self.schedMinute = [d[@"minute"] integerValue]; if (self.schedMinute<0||self.schedMinute>59) self.schedMinute=0;

    [self updateStatus:self.scheduleOn ? [NSString stringWithFormat:@"å·²å°±ç»ª Â· æ¯æ¥ %02ld:%02ld å®æ¶çæ", (long)self.schedHour, (long)self.schedMinute] : @"å·²å°±ç»ª"];

}



- (void)saveSettings {

    NSDictionary *d = @{@"enabled":@(self.enabled), @"steps":@(self.steps), @"ratio":@(self.ratio), @"flights":@(self.flights), @"scheduleOn":@(self.scheduleOn), @"hour":@(self.schedHour), @"minute":@(self.schedMinute)};

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    [ud setObject:d forKey:HBSettingsKey];

    [ud synchronize];

}



- (void)updateStatus:(NSString *)text { self.statusLabel.text = text; }

- (void)dismissKeyboard {}



- (void)showAlert:(NSString *)title message:(NSString *)message {

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"ç¡®å®" style:UIAlertActionStyleDefault handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];

}



#pragma mark - Generation



- (void)generateNow {

    if (self.busy) return;

    if (!self.enabled) { [self showAlert:@"å·²ç¦ç¨" message:@"è¯·åæå¼ãå¯ç¨ã"]; return; }

    long steps = self.steps; if (steps < 0) steps = 0;

    double distanceMeters = steps * self.ratio;

    long flights = self.flights; if (flights < 0) flights = 0;

    [self saveSettings];

    HBWriteStepsPreference(steps);

    // v2.2.6 ä¿®å¤ï¼å¿é¡»æèææ­¥æ°åå¥ HealthKitï¼å¾®ä¿¡æè½éè¿ HKStatistics è·¯å¾è¯»å°
    [self writeVirtualStepSample:steps];


    if (![HKHealthStore isHealthDataAvailable]) {

        [self updateStatus:@"æ­¤è®¾å¤ä¸æ¯æå¥åº·æ°æ®"];

        [self showAlert:@"ä¸æ¯æ" message:@"å½åè®¾å¤ä¸å¯ç¨ Apple Health"];

        return;

    }

    self.busy = YES;

    [self updateStatus:@"æ­£å¨çæè¿å¨æ°æ®..."];

    if (!self.healthStore) self.healthStore = [[HKHealthStore alloc] init];

    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];

    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];

    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];

    NSSet *shareTypes = [NSSet setWithObjects:stepType, distType, flightType, nil];

    [self.healthStore requestAuthorizationToShareTypes:shareTypes readTypes:nil completion:^(BOOL success, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            if (!success) {

                self.busy = NO;

                [self updateStatus:@"å¥åº·ææå¤±è´¥"];

                [self showAlert:@"ææå¤±è´¥" message:error ? error.localizedDescription : @"ææå¤±è´¥"];

                return;

            }

            [self updateStatus:@"æ­£å¨åå¥å¥åº·æ°æ®..."];

            [self fetchDeviceSourceRevision:^(HKSourceRevision *devRev) {

                dispatch_async(dispatch_get_main_queue(), ^{

                    [self writeSamplesSequentially:devRev stepCount:steps distanceM:distanceMeters flights:flights];

                });

            }];

        });

    }];

}



- (void)fetchDeviceSourceRevision:(void(^)(HKSourceRevision *))completion {

    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];

    NSDate *now = [NSDate date];

    NSCalendar *cal = [NSCalendar currentCalendar];

    NSDateComponents *comps = [[NSDateComponents alloc] init];

    comps.day = -7;

    NSDate *start = [cal dateByAddingComponents:comps toDate:now options:0];

    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionNone];

    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:stepType

                                                       predicate:pred

                                                           limit:200

                                                 sortDescriptors:nil

                                                  resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {

        if (error) { HBLog(@"[UCS] fetchDeviceSource error: %@", error); }

        HKSourceRevision *found = nil;

        NSArray *samples = results ?: @[];

        for (HKSample *s in samples) {

            HKSourceRevision *r = s.sourceRevision;

            if (!r) continue;

            HKSource *src = r.source;

            NSString *bid = src ? src.bundleIdentifier : nil;

            HBLog(@"[UCS] sample source: bid=%@", bid ?: @"nil");

            if (bid == nil) { found = r; break; }

            if ([bid hasPrefix:@"com.apple.health."] && !found) { found = r; }

        }

        HBLog(@"[UCS] found deviceSourceRev: %@", found ?: @"nil");

        if (completion) completion(found);

    }];

    [self.healthStore executeQuery:q];

}



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



    NSPredicate *todayPred = [HKQuery predicateForSamplesWithStartDate:startOfDay

                                                              endDate:now

                                                            options:HKQueryOptionNone];

    HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:stepType

                                                          predicate:todayPred

                                                              limit:HKObjectQueryNoLimit

                                                    sortDescriptors:nil

                                                     resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {

        if (error) {

            HBLog(@"[UCS] query error: %@", error);

            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });

            return;

        }

        NSArray *samples = results ?: @[];

        HBLog(@"[UCS] today %lu samples", (unsigned long)samples.count);



        // v2.0.1 ä¿®å¤ï¼æ£æ¥æ¯å¦å·²æçå®è®¾å¤æ­¥æ°ï¼ç¨æ·èªå·±èµ°è·¯çï¼

        // å¦ææï¼è¯´æç¨æ·å·²ç»èµ°è·¯äºï¼ä¸åºè¯¥è¦ççå®æ°æ®

        BOOL hasRealDeviceSteps = NO;

        for (HKSample *s in samples) {

            HKSourceRevision *rev = s.sourceRevision;

            if (!rev) continue;

            HKSource *src = rev.source;

            NSString *bid = src ? src.bundleIdentifier : nil;

            // è®¾å¤æºï¼bid=nilï¼æ Health App æºçæ ·æ¬

            if (bid == nil || [bid hasPrefix:@"com.apple.health."]) {

                if ([s isKindOfClass:[HKQuantitySample class]]) {

                    HKQuantitySample *qs = (HKQuantitySample *)s;

                    double stepVal = [qs.quantity doubleValueForUnit:[HKUnit countUnit]];

                    if (stepVal > 0) {

                        hasRealDeviceSteps = YES;

                        HBLog(@"[UCS] åç°çå®è®¾å¤æ­¥æ° %.0fï¼è·³è¿è¦ç", stepVal);

                        break;

                    }

                }

            }

        }

        if (hasRealDeviceSteps) {

            // å·²æçå®æ°æ®ï¼åªéåå¥è·ç¦»åæ¥¼å±ï¼ä¸å½±åæ­¥æ°ï¼

            HBLog(@"[UCS] å·²æçå®æ­¥æ°ï¼ä»è¡¥åè·ç¦»åæ¥¼å±æ°æ®");

            NSDate *sampleNow = [NSDate date];

            HKQuantityType *distType2 = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];

            HKQuantityType *flightType2 = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];

            // åæ¥è¯¢çå®æ­¥æ°æ»å

            __block long realSteps = steps; // é»è®¤ç¨è®¾ç½®å¼

            HKStatisticsQuery *sumQ = [[HKStatisticsQuery alloc] initWithQuantityType:stepType

                                                          quantitySamplePredicate:todayPred

                                                                          options:HKStatisticsOptionCumulativeSum

                                                                completionHandler:^(HKStatisticsQuery *query2, HKStatistics *result, NSError *error2) {

                if (!error2 && result) {

                    HKQuantity *sum = [result sumQuantity];

                    if (sum) realSteps = (long)[sum doubleValueForUnit:[HKUnit countUnit]];

                }

                double realDistance = realSteps * self.ratio;

                HBLog(@"[UCS] çå®æ­¥æ°=%ldï¼è·ç¦»=%.1f", realSteps, realDistance);

                // åå¥è·ç¦»

                HKQuantity *distQ = [HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:realDistance];

                HKQuantitySample *distSample = [HKQuantitySample quantitySampleWithType:distType2

                                                                                quantity:distQ

                                                                             startDate:sampleNow

                                                                               endDate:sampleNow

                                                                                 device:[HKDevice localDevice]

                                                                               metadata:nil];

                [self saveSamplePrivately:distSample completion:^(BOOL ok, NSError *e) {

                    HBLog(@"[UCS] è·ç¦»åå¥: ok=%d", ok);

                    // åå¥æ¥¼å±

                    HKQuantity *flightQ = [HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:flights];

                    HKQuantitySample *flightSample = [HKQuantitySample quantitySampleWithType:flightType2

                                                                                    quantity:flightQ

                                                                                 startDate:sampleNow

                                                                                   endDate:sampleNow

                                                                                     device:[HKDevice localDevice]

                                                                                   metadata:nil];

                    [self saveSamplePrivately:flightSample completion:^(BOOL ok2, NSError *e2) {

                        HBLog(@"[UCS] æ¥¼å±åå¥: ok=%d", ok2);

                        [self writeVirtualStepSample:steps];

                        dispatch_async(dispatch_get_main_queue(), ^{

                            [self finishSuccess:deviceRev];

                        });

                    }];

                }];

            }];

            [self.healthStore executeQuery:sumQ];

            return;

        }



        HKSource *defaultSource = [HKSource defaultSource];

        NSString *myBid = defaultSource.bundleIdentifier;

        HBLog(@"[UCS] defaultSource bid = %@", myBid ?: @"(nil)");



        NSMutableArray *deviceSamples = [NSMutableArray array];

        for (HKSample *s in samples) {

            HKSourceRevision *rev = s.sourceRevision;

            NSString *bid = rev.source.bundleIdentifier;

            BOOL isDevice = (bid == nil);

            BOOL isHealthApp = (bid != nil && [bid hasPrefix:@"com.apple.health."]);

            BOOL isMine = (myBid != nil && bid != nil && [bid isEqualToString:myBid]);

            if (isDevice || isHealthApp || isMine) [deviceSamples addObject:s];

        }

        HBLog(@"[UCS] samples to delete: %lu (of %lu)", (unsigned long)deviceSamples.count, (unsigned long)samples.count);



        __weak typeof(self) weakSelf = self;

        // ä¿®å¤(V2.0.2)ï¼ç»ä¸å é¤çå®è®¾å¤/å¥åº·æ ·æ¬ï¼ä»æ¸ææ¬ App ä¹ååçåææ ·æ¬

        // ï¼HBSyntheticStepMetaKey æ è®°ï¼ï¼é¿åçå®æ­¥æ°è¢«æ¹ãåé»è¾ä¼ deleteObject è®¾å¤/å¥åº·æºæ ·æ¬ã

        NSMutableArray *oldSynthetic = [NSMutableArray array];

        for (HKSample *s in deviceSamples) {

            if ([s.metadata[HBSyntheticStepMetaKey] boolValue]) [oldSynthetic addObject:s];

        }

        void (^startWrite)(void) = ^{

            HBLog(@"[UCS] start writing: steps=%ld dist=%.1f flights=%ld", steps, distanceMeters, flights);

            [weakSelf _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];

        };

        if (oldSynthetic.count > 0) {

            dispatch_group_t group = dispatch_group_create();

            for (HKSample *s in oldSynthetic) {

                dispatch_group_enter(group);

                [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e) {

                    HBLog(@"[UCS] delete synthetic %@: ok=%d", s.sampleType.identifier, ok);

                    dispatch_group_leave(group);

                }];

            }

            dispatch_group_notify(group, dispatch_get_main_queue(), startWrite);

        } else {

            HBLog(@"[UCS] no synthetic samples to delete");

            dispatch_async(dispatch_get_main_queue(), startWrite);

        }

    }];

    [self.healthStore executeQuery:query];

}



- (void)saveSamplePrivately:(HKQuantitySample *)sample completion:(void (^)(BOOL success, NSError *error))completion {

    SEL privSel = NSSelectorFromString(@"_saveObjects:atomically:skipInsertionFilter:completion:");

    Method m = privSel ? class_getInstanceMethod([HKHealthStore class], privSel) : NULL;

    unsigned int nargs = m ? method_getNumberOfArguments(m) : 0;

    HBLog(@"[UCS] _saveObjects åæ°ä¸ªæ°=%u (ææ 6)", nargs);

    if (!m || nargs != 6) {

        HBLog(@"[UCS] ç§æ save ä¸å¯ç¨ï¼éåå¬å¼ saveObject");

        [self.healthStore saveObject:sample withCompletion:completion];

        return;

    }

    @try {

        NSMethodSignature *sig = [self.healthStore methodSignatureForSelector:privSel];

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];

        [inv setSelector:privSel];

        NSArray *objs = @[sample];

        BOOL atomically = YES;

        BOOL skipFilter = YES;

        void (^cb)(BOOL, NSError *) = [completion copy];

        [inv setArgument:&objs      atIndex:2];

        [inv setArgument:&atomically atIndex:3];

        [inv setArgument:&skipFilter atIndex:4];

        [inv setArgument:&cb        atIndex:5];

        [inv invokeWithTarget:self.healthStore];

        HBLog(@"[UCS] å·²ç¨ç§æ _saveObjects(skipInsertionFilter:YES) æäº¤");

    } @catch (NSException *e) {

        HBLog(@"[UCS] ç§æ save å¼å¸¸: %@ -> éåå¬å¼ API", e);

        [self.healthStore saveObject:sample withCompletion:completion];

    }

}



- (void)verifyStepsWritten {

    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];

    NSDate *now = [NSDate date];

    NSDate *startOfDay = [[NSCalendar currentCalendar] startOfDayForDate:now];

    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];

    HKStatisticsQuery *q = [[HKStatisticsQuery alloc] initWithQuantityType:stepType

                                                  quantitySamplePredicate:pred

                                                                  options:HKStatisticsOptionCumulativeSum

                                                        completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {

        if (error) { HBLog(@"[UCS] VERIFY error: %@", error); return; }

        HKQuantity *sum = [result sumQuantity];

        double v = sum ? [sum doubleValueForUnit:[HKUnit countUnit]] : 0;

        HBLog(@"[UCS] VERIFY å½å¤©æ­¥æ°æ»å = %.0f", v);

        HKSampleQuery *sq = [[HKSampleQuery alloc] initWithSampleType:stepType

                                                            predicate:pred

                                                                limit:50

                                                      sortDescriptors:nil

                                                       resultsHandler:^(HKSampleQuery *q2, NSArray *results2, NSError *e2) {

            HBLog(@"[UCS] VERIFY å½å¤©æ ·æ¬æ¡æ° = %lu", (unsigned long)(results2 ?: @[]).count);

            for (HKSample *s in (results2 ?: @[])) {

                NSString *bid = s.sourceRevision.source.bundleIdentifier;

                if ([s isKindOfClass:[HKQuantitySample class]]) {

                    HKQuantitySample *qs = (HKQuantitySample *)s;

                    double sv = [qs.quantity doubleValueForUnit:[HKUnit countUnit]];

                    HBLog(@"[UCS] VERIFY æ ·æ¬: %.0f æ­¥, æ¥æº=%@", sv, bid ?: @"(nil=è®¾å¤æº)");

                }

            }

        }];

        [self.healthStore executeQuery:sq];

    }];

    [self.healthStore executeQuery:q];

}



// v2.0.xï¼æãèææ­¥æ°å¢éãåæãåææ­¥æ°æ ·æ¬ãåè¿ Healthï¼

// ä½¿ç³»ç»ãå¥åº·ãApp ä¹æ¾ç¤º çå®+èæï¼a = çå®è®¾å¤æ­¥æ° + æ­¤å¢éï¼ã

// æ³¨æåçæ¯ãå¢é vãï¼Health ä¼æçå®æ­¥æ°ä¸æ­¤å¢éæ±åå¾å° aï¼å¾®ä¿¡ tweak å·²æ¹ç´éï¼

// ç´æ¥è¯» Health åå¼ï¼ä¸ä¼åéå ãæ¯æ¬¡åç¨ metadata æ è¯å ææ§åææ ·æ¬ååæ°ï¼

// é¿åéæ¬¡è®¾ç½®ç´¯å ã

static NSString *const HBSyntheticStepMetaKey = @"com.sykes.ucs.virtualStep";



- (void)writeVirtualStepSample:(long)virtualSteps {

    if (![HKHealthStore isHealthDataAvailable]) { HBLog(@"[UCS] ä¸æ¯æå¥åº·ï¼è·³è¿åææ­¥æ°åå¥"); return; }

    if (!self.healthStore) self.healthStore = [[HKHealthStore alloc] init];

    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];

    NSCalendar *cal = [NSCalendar currentCalendar];

    NSDate *now = [NSDate date];

    NSDate *startOfDay = [cal startOfDayForDate:now];

    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];

    HKSampleQuery *delQ = [[HKSampleQuery alloc] initWithSampleType:stepType

                                                          predicate:pred

                                                              limit:HKObjectQueryNoLimit

                                                    sortDescriptors:nil

                                                     resultsHandler:^(HKSampleQuery *q, NSArray *results, NSError *e) {

            // v2.2.7ï¼ç¨ dispatch_group å¹¶è¡å æ§æ ·æ¬ï¼é¿ååæ­¥å¾ªç¯éæ¯æ¬¡ deleteObject é½ç­å®æåå ä¸ä¸ä¸ª
            dispatch_group_t group = dispatch_group_create();
            NSArray *samples = results ?: @[];
            __block BOOL groupEntered = NO; // è¿½è¸ªæ¯å¦æä»»ä½ enterï¼é²æ­¢æ æ ·æ¬æ¶ dispatch_after å¯¼è´ä¸æº¢
            for (HKSample *s in samples) {
                if ([s.metadata[HBSyntheticStepMetaKey] boolValue]) {
                    groupEntered = YES;
                    dispatch_group_enter(group);
                    [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e2){
                        HBLog(@"[UCS] å é¤æ§åææ­¥æ°æ ·æ¬ ok=%d", ok);
                        dispatch_group_leave(group);
                    }];
                }
            }

            // ä»å¨ç¡®å®æ enter æ¶æè®¾è¶æ¶ååºï¼é¿åç»è®¡æ°å¨ä¸æº¢
            if (groupEntered) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    dispatch_group_leave(group);
                });
            }

            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                if (virtualSteps > 0) {
                    HKQuantity *qty = [HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:(double)virtualSteps];
                    HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:stepType
                                                                                  quantity:qty
                                                                               startDate:startOfDay
                                                                                 endDate:now
                                                                                   device:[HKDevice localDevice]
                                                                                 metadata:@{HBSyntheticStepMetaKey: @YES}];
                    [self saveSamplePrivately:sample completion:^(BOOL ok, NSError *e3){
                        HBLog(@"[UCS] åå¥åææ­¥æ°(å¢é)%ld ok=%d", virtualSteps, ok);
                    }];
                } else {
                    HBLog(@"[UCS] èææ­¥æ°=0ï¼ä»æ¸çæ§åææ ·æ¬");
                }
            });

        }];

    [self.healthStore executeQuery:delQ];

}



- (void)_writeSteps:(long)steps dist:(double)distM flights:(long)flights deviceRev:(HKSourceRevision *)deviceRev index:(NSUInteger)index {

    // æ­¥æ°æ¹ç± writeVirtualStepSample ä»¥ãåææ ·æ¬(èæå¢é)ãåå¥ Healthï¼

    // è¿éä¸ååè®¾å¤æ­¥æ°æ ·æ¬ï¼é¿åä¸çå®è®¾å¤æ­¥æ°ååææ ·æ¬éå¤/åéå å ã

    if (index == 0) {

        [self _writeSteps:steps dist:distM flights:flights deviceRev:deviceRev index:1];

        return;

    }

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

        HBLog(@"[UCS] sample creation failed");

        dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:nil busy:YES]; });

        return;

    }

    HBLog(@"[UCS] saving %@ value=%.2f", type.identifier, value);

    [self saveSamplePrivately:sample completion:^(BOOL success, NSError *error) {

        HBLog(@"[UCS] save %@: ok=%d err=%@", type.identifier, success, error ?: @"nil");

        if (!success) {

            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });

            return;

        }

        if (index < 2) {

            [self _writeSteps:steps dist:distM flights:flights deviceRev:deviceRev index:index + 1];

        } else {

            HBLog(@"[UCS] all writes complete");

            [self writeVirtualStepSample:steps];

            dispatch_async(dispatch_get_main_queue(), ^{

                [self finishSuccess:deviceRev];

                [self verifyStepsWritten];

            });

        }

    }];

}



- (void)finishSuccess:(HKSourceRevision *)deviceRev {

    self.busy = NO;

    // è®°å½ãä»å¤©å·²çæãï¼é¿åéå¤çæï¼å®æ¶/æå¨è§¦åååå¥ï¼

    [HBTodayString() writeToFile:HBLastGenPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // v2.2.7ï¼çææåååä¿å­è®¾ç½®ï¼é¿å generateNow å¼å¤´è¿æ©åå¥é»è®¤å¼è¦çç¨æ·è®¾ç½®
    [self saveSettings];

    [self updateStatus:@"è¿å¨æ°æ®å·²çæ"];

    [self showAlert:@"è¿å¨æ°æ®å·²çæ" message:@""];

}



- (void)finishWithError:(NSError *)error busy:(BOOL)busyFlag {

    (void)busyFlag;

    self.busy = NO;

    [self updateStatus:@"åå¥å¤±è´¥"];

    NSString *msg = error ? error.localizedDescription : @"æªç¥éè¯¯";

    [self showAlert:@"åå¥å¤±è´¥" message:msg];

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

