#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

#ifndef LX_BUILD_ID
#define LX_BUILD_ID @"dev"
#endif

static NSString *const kLXBuildID = LX_BUILD_ID;
static const void *kLxRecalledFlagKey = &kLxRecalledFlagKey;
static const NSInteger kLxRecallIconTag = 0x4C585249; // LXRI
static int gLxRecallIconLogCount = 0;
static void LxLogLine(NSString *format, ...);

static void LxMarkMessageRecalled(id message) {
    if (!message) return;
    objc_setAssociatedObject(message, kLxRecalledFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LxObjcMsgSendBool(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return NO;
    return ((BOOL(*)(id, SEL))objc_msgSend)(target, sel);
}

static id LxObjcMsgSendId(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(target, sel);
}

static UIView *LxObjcMsgSendView(id target, SEL sel) {
    id value = LxObjcMsgSendId(target, sel);
    return [value isKindOfClass:[UIView class]] ? (UIView *)value : nil;
}

static BOOL LxIsMessageRecalled(id message) {
    if (!message) return NO;
    NSNumber *flag = objc_getAssociatedObject(message, kLxRecalledFlagKey);
    if (flag.boolValue) return YES;
    if (LxObjcMsgSendBool(message, @selector(isRecalled))) return YES;
    if (LxObjcMsgSendBool(message, @selector(recalled))) return YES;
    return NO;
}

static id LxExtractCoreMessage(id obj) {
    if (!obj) return nil;
    SEL sels[] = {
        @selector(message),
        @selector(msgData),
        @selector(chatData),
        @selector(msg),
        @selector(msgModel),
        @selector(coreMessage)
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        id v = LxObjcMsgSendId(obj, sels[i]);
        if (v && v != obj) return v;
    }
    return nil;
}

static BOOL LxIsLikelyMessageContextObject(id obj) {
    if (!obj) return NO;
    if ([obj isKindOfClass:[UIView class]]) return NO;
    if ([obj isKindOfClass:[UIViewController class]]) return NO;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return NO;

    if (LxIsMessageRecalled(obj)) return YES;
    if ([obj respondsToSelector:@selector(msgState)] || [obj respondsToSelector:@selector(setMsgState:)]) return YES;
    if ([obj respondsToSelector:@selector(chatData)] || [obj respondsToSelector:@selector(msgData)] ||
        [obj respondsToSelector:@selector(msg)] || [obj respondsToSelector:@selector(message)]) return YES;

    NSString *cn = NSStringFromClass([obj class]).lowercaseString ?: @"";
    if ([cn containsString:@"imcoremessage"] || [cn containsString:@"chatdata"] ||
        [cn containsString:@"msgmodel"] || [cn containsString:@"message"]) {
        return YES;
    }
    return NO;
}

static BOOL LxIvarNameLooksLikeMessage(NSString *name) {
    if (name.length == 0) return NO;
    NSString *s = name.lowercaseString;
    return [s containsString:@"chatdata"] ||
           [s isEqualToString:@"msg"] ||
           [s containsString:@"message"] ||
           [s containsString:@"msgdata"] ||
           [s containsString:@"msgmodel"] ||
           [s containsString:@"model"] ||
           [s containsString:@"item"] ||
           [s containsString:@"core"];
}

static BOOL LxVisitObject(NSMutableSet<NSValue *> *visited, id obj) {
    if (!visited || !obj) return NO;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)(obj)];
    if ([visited containsObject:key]) return NO;
    [visited addObject:key];
    return YES;
}

static id LxFindContextByIvars(id obj, BOOL nameHintOnly) {
    if (!obj) return nil;
    for (Class cls = [obj class]; cls; cls = class_getSuperclass(cls)) {
        if (cls == [NSObject class]) break;
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            const char *nameC = ivar_getName(ivar);
            NSString *name = nameC ? [NSString stringWithUTF8String:nameC] : @"";
            if (nameHintOnly && !LxIvarNameLooksLikeMessage(name)) continue;
            id v = object_getIvar(obj, ivar);
            if (!v || v == obj) continue;
            if (LxIsLikelyMessageContextObject(v)) {
                free(ivars);
                return v;
            }
        }
        free(ivars);
    }
    return nil;
}

static id LxFindContextByScan(id obj, NSInteger depth, NSMutableSet<NSValue *> *visited) {
    if (!obj || depth < 0 || !visited) return nil;
    if (!LxVisitObject(visited, obj)) return nil;

    if (LxIsLikelyMessageContextObject(obj)) return obj;
    if (depth == 0) return nil;
    if ([obj isKindOfClass:[UIView class]] || [obj isKindOfClass:[CALayer class]]) return nil;

    SEL sels[] = {
        @selector(chatData),
        @selector(msg),
        @selector(message),
        @selector(msgData),
        @selector(chatDataWhenTouchBegin),
        @selector(model),
        @selector(item),
        @selector(coreMessage),
        @selector(msgModel)
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        id v = LxObjcMsgSendId(obj, sels[i]);
        if (!v || v == obj) continue;
        if (LxIsLikelyMessageContextObject(v)) return v;
        id vv = LxFindContextByScan(v, depth - 1, visited);
        if (vv) return vv;
    }

    id v1 = LxFindContextByIvars(obj, YES);
    if (v1) return v1;
    id v2 = LxFindContextByIvars(obj, NO);
    if (v2) return v2;
    return nil;
}

static BOOL LxIsRecalledContext(id obj) {
    if (!obj) return NO;
    if (LxIsMessageRecalled(obj)) return YES;
    id core = LxExtractCoreMessage(obj);
    if (core && LxIsMessageRecalled(core)) return YES;
    id core2 = core ? LxExtractCoreMessage(core) : nil;
    if (core2 && LxIsMessageRecalled(core2)) return YES;
    return NO;
}

static id LxMessageContextFromCell(id cell) {
    if (!cell) return nil;
    SEL sels[] = {
        @selector(chatData),
        @selector(msg),
        @selector(message),
        @selector(msgData),
        @selector(chatDataWhenTouchBegin),
        @selector(model)
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        id v = LxObjcMsgSendId(cell, sels[i]);
        if (!v) continue;
        if (LxIsLikelyMessageContextObject(v)) return v;
        id core = LxExtractCoreMessage(v);
        if (core) return core;
    }

    id ivarHit = LxFindContextByIvars(cell, YES);
    if (ivarHit) return ivarHit;

    NSMutableSet<NSValue *> *visited = [NSMutableSet setWithCapacity:24];
    id scanHit = LxFindContextByScan(cell, 2, visited);
    if (scanHit) return scanHit;
    return nil;
}

static UIImage *LxRecallIconImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *base = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Frameworks/App.framework/flutter_assets/packages/flutter_assets/assets/images"];
        NSArray<NSString *> *candidates = @[
            [base stringByAppendingPathComponent:@"3.0x/emoticonreply_refresh.png"],
            [base stringByAppendingPathComponent:@"2.0x/emoticonreply_refresh.png"],
            [base stringByAppendingPathComponent:@"emoticonreply_refresh.png"]
        ];
        for (NSString *p in candidates) {
            UIImage *img = [UIImage imageWithContentsOfFile:p];
            if (img) {
                image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
                break;
            }
        }
        if (!image) image = [[UIImage imageNamed:@"emoticonreply_refresh"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return image;
}

static void LxCollectSubviews(UIView *view, NSMutableArray<UIView *> *out) {
    if (!view || !out) return;
    for (UIView *sub in view.subviews) {
        [out addObject:sub];
        LxCollectSubviews(sub, out);
    }
}

static UIView *LxFindBubbleContainer(id cell) {
    SEL sels[] = {
        @selector(msgBackView),
        @selector(contentBgView),
        @selector(contentContainerView),
        @selector(bubbleView),
        @selector(bodyView),
        @selector(textContentView)
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        UIView *v = LxObjcMsgSendView(cell, sels[i]);
        if (v && CGRectGetWidth(v.bounds) > 40 && CGRectGetHeight(v.bounds) > 20) return v;
    }
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        UIView *content = ((UITableViewCell *)cell).contentView;
        if (content) {
            NSMutableArray<UIView *> *subs = [NSMutableArray array];
            LxCollectSubviews(content, subs);
            UIView *best = nil;
            CGFloat bestArea = 0;
            CGFloat contentW = CGRectGetWidth(content.bounds);
            for (UIView *v in subs) {
                if (v.hidden || v.alpha < 0.01) continue;
                CGRect rf = [content convertRect:v.bounds fromView:v];
                CGFloat w = CGRectGetWidth(rf);
                CGFloat h = CGRectGetHeight(rf);
                if (w < 60.0 || h < 20.0) continue;
                if (contentW > 0 && w > contentW - 14.0) continue;
                CGFloat area = w * h;
                if (area > bestArea) {
                    best = v;
                    bestArea = area;
                }
            }
            if (best) return best;
        }
    }
    return nil;
}

static BOOL LxIsChatMsgCell(id cell) {
    if (!cell) return NO;
    NSString *cls = NSStringFromClass([cell class]).lowercaseString ?: @"";
    if (cls.length == 0) return NO;
    return [cls isEqualToString:@"lxchatmsgcell"] || [cls containsString:@"lxchatmsgcell"];
}

static void LxApplyRecallIconToCell(id cell, NSString *reason) {
    if (![cell isKindOfClass:[UIView class]]) return;
    if (!LxIsChatMsgCell(cell)) return;
    UIView *cellView = (UIView *)cell;
    UIImageView *iconView = (UIImageView *)[cellView viewWithTag:kLxRecallIconTag];
    id msgContext = LxMessageContextFromCell(cell);
    BOOL recalled = LxIsRecalledContext(msgContext);
    if (!recalled) {
        if (iconView) {
            BOOL wasVisible = !iconView.hidden;
            iconView.hidden = YES;
            if (wasVisible && gLxRecallIconLogCount < 160) {
                gLxRecallIconLogCount++;
                LxLogLine(@"[LXPATCH] recall icon hide cell=%@ ptr=%p reason=%@", NSStringFromClass([cell class]), cell, reason ?: @"(nil)");
            }
        }
        return;
    }

    UIImage *iconImage = LxRecallIconImage();
    if (!iconImage) {
        if (gLxRecallIconLogCount < 160) {
            gLxRecallIconLogCount++;
            LxLogLine(@"[LXPATCH] recall icon error=no-image cell=%@ ptr=%p reason=%@",
                      NSStringFromClass([cell class]), cell, reason ?: @"(nil)");
        }
        return;
    }

    UIView *bubble = LxFindBubbleContainer(cell);
    if (!bubble) {
        if (gLxRecallIconLogCount < 160) {
            gLxRecallIconLogCount++;
            LxLogLine(@"[LXPATCH] recall icon error=no-bubble cell=%@ ptr=%p reason=%@",
                      NSStringFromClass([cell class]), cell, reason ?: @"(nil)");
        }
        return;
    }
    CGFloat bw = CGRectGetWidth(bubble.bounds);
    CGFloat bh = CGRectGetHeight(bubble.bounds);
    if (bw < 20.0 || bh < 12.0) return;

    UIView *host = bubble;
    CGFloat size = 16.0;
    CGFloat insetX = 3.0;
    CGFloat insetY = 2.0;
    CGFloat x = MAX(0.0, bw - size - insetX);
    CGFloat y = insetY;
    CGRect target = CGRectIntegral(CGRectMake(x, y, size, size));

    if (target.origin.x + target.size.width > bw) {
        target.origin.x = MAX(0.0, bw - target.size.width);
    }

    if (!iconView) {
        iconView = [[UIImageView alloc] initWithImage:iconImage];
        iconView.tag = kLxRecallIconTag;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
    iconView.image = iconImage;
    if (iconView.superview != host) {
        [iconView removeFromSuperview];
        [host addSubview:iconView];
    }
    iconView.frame = target;
    iconView.hidden = NO;
    if (gLxRecallIconLogCount < 160) {
        gLxRecallIconLogCount++;
        LxLogLine(@"[LXPATCH] recall icon show cell=%@ ptr=%p reason=%@ frame={%.1f,%.1f,%.1f,%.1f}",
                  NSStringFromClass([cell class]),
                  cell,
                  reason ?: @"(nil)",
                  target.origin.x, target.origin.y, target.size.width, target.size.height);
    }
}

%hook LxChatMsgCell

- (void)didMoveToWindow {
    %orig;
    LxApplyRecallIconToCell(self, @"LxChatMsgCell.didMoveToWindow");
}

- (void)layoutSubviews {
    %orig;
    LxApplyRecallIconToCell(self, @"LxChatMsgCell.layoutSubviews");
}

%end

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
        LxMarkMessageRecalled(self);
        LxLogLine(@"[LXPATCH] msgState remap self=%p from=%d to=5", self, state);
        return 5;
    }
    return state;
}

- (void)setMsgState:(int)state {
    if (state == 6 || state == 7) {
        LxMarkMessageRecalled(self);
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
