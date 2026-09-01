// HBScout - 诊断用：注入所有进程，把每个进程的 真实 bundle id + 可执行文件名 写进文本日志。
// 目的：搞清楚「微信在 roothide 下到底以什么标识运行」，从而修正 HealthBoost 的 filter。
// 构造函数极简、只写文件，不 hook 任何东西，注入到任何进程都安全。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <unistd.h>
#include <sys/stat.h>

static void HBScoutLog(NSString *msg) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"(null)";
    NSString *exe = [NSProcessInfo processInfo].processName ?: @"(null)";
    NSString *line = [NSString stringWithFormat:@"SCOUT %@ bid=%@ exe=%@ pid=%d\n",
                      msg, bid, exe, (int)getpid()];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];

    // 1) 自身容器 Documents（沙盒内必定可写；HealthBoost App 的「查看日志」会收集这个文件）
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count) {
        NSString *p = [docs[0] stringByAppendingPathComponent:@"hb_tweak_log.txt"];
        if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
    }

    // 2) 共享 Media（无沙盒进程可写；有沙盒的微信若写不进就忽略，不影响诊断）
    NSString *mp = @"/var/mobile/Media/HealthBoost/scout.txt";
    [fm createDirectoryAtPath:[mp stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:mp]) [fm createFileAtPath:mp contents:nil attributes:nil];
    NSFileHandle *mh = [NSFileHandle fileHandleForWritingAtPath:mp];
    if (mh) { [mh seekToEndOfFile]; [mh writeData:d]; [mh closeFile]; }
}

__attribute__((constructor))
static void hbscout_init(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    HBScoutLog([f stringFromDate:[NSDate date]]);
}
