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
static int gLxMessageCtxLogCount = 0;
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

static BOOL LxIsOutgoingContext(id obj) {
    if (!obj) return NO;
    SEL boolSels[] = {
        @selector(isSendBySelf),
        @selector(isSenderSelf),
        @selector(isSelfSend),
        @selector(isMySelf),
        @selector(isFromSelf),
        @selector(outgoing),
        @selector(isOutgoing)
    };
    for (size_t i = 0; i < sizeof(boolSels) / sizeof(boolSels[0]); i++) {
        if (LxObjcMsgSendBool(obj, boolSels[i])) return YES;
    }
    id core = LxExtractCoreMessage(obj);
    if (core && core != obj) {
        for (size_t i = 0; i < sizeof(boolSels) / sizeof(boolSels[0]); i++) {
            if (LxObjcMsgSendBool(core, boolSels[i])) return YES;
        }
    }
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

    if (gLxMessageCtxLogCount < 80) {
        gLxMessageCtxLogCount++;
        LxLogLine(@"[LXPATCH] ctx-miss class=%@", NSStringFromClass([cell class]) ?: @"(nil)");
    }
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
        @selector(contentView),
        @selector(bubbleView),
        @selector(bodyView),
        @selector(textContentView)
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        UIView *v = LxObjcMsgSendView(cell, sels[i]);
        if (v && CGRectGetWidth(v.bounds) > 40 && CGRectGetHeight(v.bounds) > 20) return v;
    }
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        return ((UITableViewCell *)cell).contentView;
    }
    return [cell isKindOfClass:[UIView class]] ? (UIView *)cell : nil;
}

static UIView *LxFindReactionHost(UIView *bubble) {
    if (!bubble) return nil;
    NSMutableArray<UIView *> *subs = [NSMutableArray array];
    LxCollectSubviews(bubble, subs);
    for (UIView *v in subs) {
        NSString *cn = NSStringFromClass([v class]).lowercaseString ?: @"";
        if (cn.length == 0) continue;
        if ([cn containsString:@"reply"] || [cn containsString:@"reaction"] || [cn containsString:@"emoji"] || [cn containsString:@"emoticon"]) {
            if (!v.hidden && v.alpha > 0.01) return v.superview ?: v;
        }
    }
    return nil;
}

static BOOL LxFindReactionSeedFrame(UIView *host, CGRect *outFrame) {
    if (!host || !outFrame) return NO;
    NSMutableArray<UIView *> *subs = [NSMutableArray array];
    LxCollectSubviews(host, subs);
    for (UIView *v in subs) {
        if (![v isKindOfClass:[UIImageView class]]) continue;
        if (v.hidden || v.alpha < 0.01) continue;
        CGRect rf = [host convertRect:v.bounds fromView:v];
        CGFloat w = CGRectGetWidth(rf);
        CGFloat h = CGRectGetHeight(rf);
        if (w >= 12 && h >= 12 && w <= 42 && h <= 42 && CGRectGetMinY(rf) >= CGRectGetHeight(host.bounds) * 0.35) {
            *outFrame = rf;
            return YES;
        }
    }
    return NO;
}

static NSMutableSet<NSString *> *LxDiscoveredCellClasses(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static BOOL LxShouldProcessMessageCell(UITableViewCell *cell, BOOL *outHasContext) {
    if (!cell) return NO;
    id ctx = LxMessageContextFromCell(cell);
    BOOL hasContext = (ctx != nil);
    if (outHasContext) *outHasContext = hasContext;
    if (hasContext) return YES;

    NSString *cls = NSStringFromClass([cell class]).lowercaseString ?: @"";
    if (cls.length == 0) return NO;
    if ([cls containsString:@"chatmsg"] || [cls containsString:@"messagecell"] || [cls containsString:@"msgcell"]) return YES;
    if ([cls containsString:@"chat"] && [cls containsString:@"cell"]) return YES;
    if ([cls containsString:@"aurora"] && [cls containsString:@"message"]) return YES;
    return NO;
}

static void LxLogCellDiscoveryIfNeeded(UITableViewCell *cell, BOOL hasContext, NSString *reason) {
    NSString *cls = NSStringFromClass([cell class]) ?: @"(nil)";
    NSMutableSet<NSString *> *set = LxDiscoveredCellClasses();
    BOOL shouldLog = NO;
    @synchronized (set) {
        if (![set containsObject:cls]) {
            [set addObject:cls];
            shouldLog = YES;
        }
    }
    if (shouldLog) {
        LxLogLine(@"[LXPATCH] cell-discovery class=%@ hasMessageCtx=%d reason=%@", cls, hasContext ? 1 : 0, reason ?: @"(nil)");
    }
}

static void LxApplyRecallIconToCell(id cell, NSString *reason) {
    if (![cell isKindOfClass:[UIView class]]) return;
    UIView *cellView = (UIView *)cell;
    UIImageView *iconView = (UIImageView *)[cellView viewWithTag:kLxRecallIconTag];
    id msgContext = LxMessageContextFromCell(cell);
    BOOL recalled = LxIsRecalledContext(msgContext);
    if (!recalled) {
        if (iconView) {
            iconView.hidden = YES;
            if (gLxRecallIconLogCount < 200) {
                gLxRecallIconLogCount++;
                LxLogLine(@"[LXPATCH] recall icon remove cell=%@ ptr=%p reason=%@", NSStringFromClass([cell class]), cell, reason ?: @"(nil)");
            }
        }
        return;
    }

    UIImage *iconImage = LxRecallIconImage();
    if (!iconImage) {
        if (gLxRecallIconLogCount < 200) {
            gLxRecallIconLogCount++;
            LxLogLine(@"[LXPATCH] recall icon skip-no-image cell=%@ ptr=%p reason=%@", NSStringFromClass([cell class]), cell, reason ?: @"(nil)");
        }
        return;
    }

    UIView *bubble = LxFindBubbleContainer(cell);
    if (!bubble) return;
    UIView *host = LxFindReactionHost(bubble) ?: bubble;
    CGRect target = CGRectZero;
    if (LxFindReactionSeedFrame(host, &target)) {
        if (gLxRecallIconLogCount < 200) {
            gLxRecallIconLogCount++;
            LxLogLine(@"[LXPATCH] recall icon apply cell=%@ ptr=%p reason=%@ host=%@ mode=container",
                      NSStringFromClass([cell class]), cell, reason ?: @"(nil)", NSStringFromClass([host class]));
        }
    } else {
        BOOL outgoing = LxIsOutgoingContext(msgContext) || LxIsOutgoingContext(cell);
        CGFloat size = 18.0;
        CGFloat x = outgoing ? (CGRectGetWidth(host.bounds) - size - 6.0) : 6.0;
        CGFloat y = MAX(2.0, CGRectGetHeight(host.bounds) - size - 4.0);
        target = CGRectMake(x, y, size, size);
        if (gLxRecallIconLogCount < 200) {
            gLxRecallIconLogCount++;
            LxLogLine(@"[LXPATCH] recall icon apply cell=%@ ptr=%p reason=%@ side=%@ mode=fallback",
                      NSStringFromClass([cell class]), cell, reason ?: @"(nil)", outgoing ? @"self" : @"other");
        }
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
}

%hook UITableViewCell

- (void)didMoveToWindow {
    %orig;
    BOOL hasContext = NO;
    if (!LxShouldProcessMessageCell(self, &hasContext)) return;
    LxLogCellDiscoveryIfNeeded(self, hasContext, @"UITableViewCell.didMoveToWindow");
    LxApplyRecallIconToCell(self, @"UITableViewCell.didMoveToWindow");
}

- (void)layoutSubviews {
    %orig;
    BOOL hasContext = NO;
    if (!LxShouldProcessMessageCell(self, &hasContext)) return;
    LxLogCellDiscoveryIfNeeded(self, hasContext, @"UITableViewCell.layoutSubviews");
    LxApplyRecallIconToCell(self, @"UITableViewCell.layoutSubviews");
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
