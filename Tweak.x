#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

#ifndef LX_BUILD_ID
#define LX_BUILD_ID @"dev"
#endif

static NSString *const kLXBuildID = LX_BUILD_ID;

static NSString *LxPrimaryLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Caches/lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

static NSString *LxFallbackLogPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) tmp = @"/tmp";
    return [tmp stringByAppendingPathComponent:
            [NSString stringWithFormat:@"lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

static NSString *LxBuildIDPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/lanxincrack.buildid"];
}

static BOOL LxAppendRawLineToPath(NSString *path, NSString *line) {
    if (path.length == 0 || line.length == 0) return NO;
    const char *fsPath = [path fileSystemRepresentation];
    const char *bytes = [line UTF8String];
    if (!fsPath || !bytes) return NO;

    int fd = open(fsPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) return NO;
    size_t len = strlen(bytes);
    ssize_t wrote = write(fd, bytes, len);
    close(fd);
    return (wrote >= 0 && (size_t)wrote == len);
}

static void LxLogLine(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!body) return;

    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });

    NSString *time = [formatter stringFromDate:[NSDate date]];
    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n", time, proc, body];
    if (LxAppendRawLineToPath(LxPrimaryLogPath(), line)) return;
    (void)LxAppendRawLineToPath(LxFallbackLogPath(), line);
}

%ctor {
    @autoreleasepool {
        NSString *buildLine = [NSString stringWithFormat:@"%@\nprimary=%@\nfallback=%@\n",
                               kLXBuildID ?: @"(nil)", LxPrimaryLogPath(), LxFallbackLogPath()];
        [buildLine writeToFile:LxBuildIDPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        LxLogLine(@"[LXBUILD] id=%@ proc=%@ pid=%d primaryLog=%@ fallbackLog=%@ buildidPath=%@",
                  kLXBuildID,
                  [[NSProcessInfo processInfo] processName],
                  getpid(),
                  LxPrimaryLogPath(),
                  LxFallbackLogPath(),
                  LxBuildIDPath());
    }
}

// ---- Anti recall (core remap only) ----
%hook IMCoreMessage

- (int)msgState {
    int state = %orig;
    if (state == 6 || state == 7) {
        LxLogLine(@"[LXPATCH] msgState remap self=%p from=%d to=5", self, state);
        return 5;
    }
    return state;
}

- (void)setMsgState:(int)state {
    if (state == 6 || state == 7) {
        %orig(5);
        LxLogLine(@"[LXPATCH] setMsgState remap self=%p from=%d to=5", self, state);
        return;
    }
    %orig(state);
}

%end

// ---- Watermark disable ----
%hook LxOrgClientModel

- (BOOL)show_watermark { return NO; }
- (id)show_watermark_types { return nil; }
- (void)setShow_watermark:(BOOL)show { %orig(NO); }
- (void)setShow_watermark_types:(id)types { %orig(nil); }

%end

%hook WatermarkService

+ (void)hiddenWatermark:(BOOL)hidden { %orig(YES); }
- (BOOL)isShowWatermark { return NO; }
- (BOOL)complyWatermarkRule:(id)viewController { return NO; }
- (void)configViewControllerWatermark:(id)viewController {}
- (void)updateWatermarkDateIfNeeded {}

%end

// ---- Splash skip ----
%hook LxSplashManager

+ (void)startPageViewShowWithOid:(int)oid launchOptions:(id)launchOptions gestureBiometricBlock:(id)gestureBiometricBlock {
    if (gestureBiometricBlock) {
        ((void (^)(void))gestureBiometricBlock)();
        LxLogLine(@"[LXPATCH] splash bypass done oid=%d", oid);
        return;
    }
    %orig;
}

%end

// ---- Jailbreak bypass ----
%hook sub_1000010100215841
+ (BOOL)sub_1000010100215849 { return NO; }
+ (void)sub_1000010100215846 {}
+ (void)sub_1000010100215842 {}
+ (void)sub_1000010100215847 {}
+ (void)sub_1000010100215845 {}
%end

%hook sub_1000010100215832
+ (BOOL)sub_1000010100215833 { return NO; }
+ (BOOL)sub_1000010100215834 { return NO; }
+ (BOOL)sub_1000010100215837 { return NO; }
%end

%hook sub_2105813100215866
+ (BOOL)autoCheck { return NO; }
%end

%hook sub_1000010100215866
+ (BOOL)sub_1000010100215867:(id)arg1 { return NO; }
%end

%hook sub_3108813100215323
+ (void)autocheck {}
+ (void)checkRoot {}
%end

%hook CoreMessUtils
+ (BOOL)isJailBreak { return NO; }
+ (BOOL)isJailBreak1 { return NO; }
+ (BOOL)isJailBreak2 { return NO; }
+ (BOOL)isJailBreak3 { return NO; }
+ (BOOL)isJailBreak4 { return NO; }
+ (BOOL)isJailBreak5 { return NO; }
+ (BOOL)isJailBreak6 { return NO; }
+ (BOOL)isJailBreak7 { return NO; }
+ (BOOL)isJailBreak8 { return NO; }
%end
