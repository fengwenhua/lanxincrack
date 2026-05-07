#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <limits.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

static const NSInteger kLxRecalledBadgeTag = 0x4C585245; // "LXRE"
static const void *kLxRecalledFlagKey = &kLxRecalledFlagKey;

static NSString *LxPrimaryLogPath(void) {
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/lanxincrack.log"];
}

static NSString *LxFallbackLogPath(void) {
	NSString *tmp = NSTemporaryDirectory();
	if (tmp.length == 0) {
		tmp = @"/tmp";
	}
	return [tmp stringByAppendingPathComponent:@"lanxincrack.log"];
}

static BOOL LxAppendRawLineToPath(NSString *path, NSString *line, int *outErrno) {
	if (outErrno) *outErrno = 0;
	if (path.length == 0 || line.length == 0) return NO;

	const char *fsPath = [path fileSystemRepresentation];
	const char *bytes = [line UTF8String];
	if (!fsPath || !bytes) return NO;

	int fd = open(fsPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
	if (fd < 0) {
		if (outErrno) *outErrno = errno;
		return NO;
	}

	size_t len = strlen(bytes);
	ssize_t wrote = write(fd, bytes, len);
	int writeErr = (wrote < 0 || (size_t)wrote != len) ? errno : 0;
	close(fd);
	if (writeErr != 0) {
		if (outErrno) *outErrno = writeErr;
		return NO;
	}
	return YES;
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
	NSString *primary = LxPrimaryLogPath();
	NSString *fallback = LxFallbackLogPath();
	int primaryErr = 0;
	NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n", time, proc, body];
	if (LxAppendRawLineToPath(primary, line, &primaryErr)) return;

	int fallbackErr = 0;
	if (LxAppendRawLineToPath(fallback, line, &fallbackErr)) {
		static dispatch_once_t fallbackNoteOnce;
		dispatch_once(&fallbackNoteOnce, ^{
			NSString *note = [NSString stringWithFormat:
				@"[%@][%@] logger fallback path=%@ primary=%@ primaryErr=%d\n",
				time, proc, fallback, primary, primaryErr];
			(void)LxAppendRawLineToPath(fallback, note, NULL);
		});
		return;
	}

	static dispatch_once_t dropNoteOnce;
	dispatch_once(&dropNoteOnce, ^{
		NSLog(@"[lanxincrack] log write failed primary=%@ err=%d fallback=%@ err=%d",
		      primary, primaryErr, fallback, fallbackErr);
	});
}

static inline id LxObjcMsgSendId(id target, SEL selector) {
	if (!target || !selector) return nil;
	if (![target respondsToSelector:selector]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static inline void LxObjcMsgSendVoidId(id target, SEL selector, id arg) {
	if (!target || !selector) return;
	if (![target respondsToSelector:selector]) return;
	((void (*)(id, SEL, id))objc_msgSend)(target, selector, arg);
}

static inline int LxObjcMsgSendInt(id target, SEL selector, int defaultValue) {
	if (!target || !selector) return defaultValue;
	if (![target respondsToSelector:selector]) return defaultValue;
	return ((int (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSString *LxClassName(id obj) {
	return obj ? NSStringFromClass([obj class]) : @"(nil)";
}

static NSHashTable *LxRecalledChatDataSet(void) {
	static NSHashTable *set = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		set = [NSHashTable weakObjectsHashTable];
	});
	return set;
}

static void LxTrackRecalledChatData(id chatData, BOOL recalled) {
	if (!chatData) return;
	objc_setAssociatedObject(chatData, kLxRecalledFlagKey, @(recalled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	NSHashTable *set = LxRecalledChatDataSet();
	@synchronized (set) {
		if (recalled) {
			[set addObject:chatData];
		} else {
			[set removeObject:chatData];
		}
	}
	LxLogLine(@"track chatData=%p recalled=%d", chatData, recalled ? 1 : 0);
}

static BOOL LxIsRecalledChatData(id chatData) {
	if (!chatData) return NO;
	NSNumber *flag = objc_getAssociatedObject(chatData, kLxRecalledFlagKey);
	if (flag.boolValue) return YES;
	NSHashTable *set = LxRecalledChatDataSet();
	@synchronized (set) {
		return [set containsObject:chatData];
	}
}

static NSMutableSet *LxRecalledMessageKeySet(void) {
	static NSMutableSet *set = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		set = [NSMutableSet set];
	});
	return set;
}

static NSString *LxMessageKeyFromObject(id obj) {
	if (!obj) return nil;

	static NSArray<NSString *> *objSelectors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		objSelectors = @[@"msgId", @"messageId", @"coreMessageId", @"uuid", @"serverMsgId", @"localMsgId"];
	});

	for (NSString *name in objSelectors) {
		SEL sel = NSSelectorFromString(name);
		id value = LxObjcMsgSendId(obj, sel);
		if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) {
			return [NSString stringWithFormat:@"%@:%@", name, value];
		}
		if ([value isKindOfClass:[NSNumber class]]) {
			return [NSString stringWithFormat:@"%@:%@", name, value];
		}
	}

	static NSArray<NSString *> *intSelectors;
	static dispatch_once_t onceToken2;
	dispatch_once(&onceToken2, ^{
		intSelectors = @[@"sequence", @"msgSeq", @"localSeq"];
	});

	for (NSString *name in intSelectors) {
		SEL sel = NSSelectorFromString(name);
		if (![obj respondsToSelector:sel]) continue;
		int n = LxObjcMsgSendInt(obj, sel, INT_MIN);
		if (n != INT_MIN && n > 0) {
			return [NSString stringWithFormat:@"%@:%d", name, n];
		}
	}

	return nil;
}

static void LxTrackRecalledMessageKeyIfAny(id obj) {
	NSString *key = LxMessageKeyFromObject(obj);
	if (key.length == 0) return;
	NSMutableSet *set = LxRecalledMessageKeySet();
	@synchronized (set) {
		[set addObject:key];
	}
	LxLogLine(@"track key=%@", key);
}

static BOOL LxIsRecalledMessageByKey(id obj) {
	NSString *key = LxMessageKeyFromObject(obj);
	if (key.length == 0) return NO;
	NSMutableSet *set = LxRecalledMessageKeySet();
	@synchronized (set) {
		return [set containsObject:key];
	}
}

static BOOL LxIsRecalledMessageObject(id obj) {
	if (LxIsRecalledChatData(obj)) return YES;
	if (LxIsRecalledMessageByKey(obj)) {
		LxTrackRecalledChatData(obj, YES);
		return YES;
	}
	return NO;
}

%ctor {
	@autoreleasepool {
		LxLogLine(@"constructor loaded primaryLog=%@ fallbackLog=%@", LxPrimaryLogPath(), LxFallbackLogPath());
	}
}

%hook sub_1000010100215841

+ (BOOL)sub_1000010100215849 {
	return NO;
}

+ (void)sub_1000010100215846 {
}

+ (void)sub_1000010100215842 {
}

+ (void)sub_1000010100215847 {
}

+ (void)sub_1000010100215845 {
}

%end

%hook IMCoreMessage

- (int)msgState {
	int state = %orig;
	LxLogLine(@"msgState self=%p orig=%d", self, state);
	if (state == 5 && LxIsRecalledMessageByKey(self)) {
		LxTrackRecalledChatData(self, YES);
		LxLogLine(@"msgState key-hit self=%p", self);
	}
	if (state == 6 || state == 7) {
		LxTrackRecalledChatData(self, YES);
		LxTrackRecalledMessageKeyIfAny(self);
		LxLogLine(@"msgState remap self=%p from=%d to=5", self, state);
		return 5;
	}
	return state;
}

- (void)setMsgState:(int)state {
	LxLogLine(@"setMsgState self=%p input=%d", self, state);
	if (state == 6 || state == 7) {
		LxTrackRecalledChatData(self, YES);
		LxTrackRecalledMessageKeyIfAny(self);
		static int stackDumpCount = 0;
		if (stackDumpCount < 2) {
			stackDumpCount++;
			LxLogLine(@"setMsgState stack=%@", [NSThread callStackSymbols]);
		}
		%orig(5);
		LxLogLine(@"setMsgState remap self=%p from=%d to=5", self, state);
		return;
	}
	LxTrackRecalledChatData(self, NO);
	%orig(state);
	LxLogLine(@"setMsgState pass self=%p state=%d", self, state);
}

- (id)messageContent {
	id content = %orig;
	if (!LxIsRecalledMessageObject(self)) {
		return content;
	}

	if ([content isKindOfClass:[NSString class]]) {
		NSString *s = (NSString *)content;
		if (![s hasPrefix:@"[已撤回]"]) {
			NSString *patched = [NSString stringWithFormat:@"[已撤回] %@", s];
			LxLogLine(@"messageContent patch string self=%p", self);
			return patched;
		}
		return s;
	}

	id text = LxObjcMsgSendId(content, @selector(text));
	if ([text isKindOfClass:[NSString class]]) {
		NSString *s = (NSString *)text;
		if (![s hasPrefix:@"[已撤回]"]) {
			NSString *patched = [NSString stringWithFormat:@"[已撤回] %@", s];
			LxObjcMsgSendVoidId(content, @selector(setText:), patched);
			LxLogLine(@"messageContent patch content.text self=%p class=%@", self, LxClassName(content));
		}
		return content;
	}

	id textMedia = LxObjcMsgSendId(content, @selector(textMedia));
	id mediaText = LxObjcMsgSendId(textMedia, @selector(text));
	if ([mediaText isKindOfClass:[NSString class]]) {
		NSString *s = (NSString *)mediaText;
		if (![s hasPrefix:@"[已撤回]"]) {
			NSString *patched = [NSString stringWithFormat:@"[已撤回] %@", s];
			LxObjcMsgSendVoidId(textMedia, @selector(setText:), patched);
			LxLogLine(@"messageContent patch textMedia.text self=%p", self);
		}
		return content;
	}

	return content;
}

%end

%hook LxCellSceneGroupRecordHelper

+ (id)builderWithChatData:(id)chatData {
	int state = LxObjcMsgSendInt(chatData, @selector(msgState), -1);
	BOOL recalled = (state == 6 || state == 7);
	LxTrackRecalledChatData(chatData, recalled);
	id builder = %orig;
	LxLogLine(@"builderWithChatData chatData=%p state=%d recalled=%d builder=%@",
	          chatData, state, recalled ? 1 : 0, LxClassName(builder));
	return builder;
}

%end

%hook LxCellTemplateMyGroupRecord

- (id)layoutUIByParentView:(id)parentView builder:(id)builder msgData:(id)msgData metaData:(id)metaData {
	id result = %orig;
	int msgState = LxObjcMsgSendInt(msgData, @selector(msgState), -1);
	NSString *builderName = LxClassName(builder);
	BOOL builderLooksRevoke = [builderName rangeOfString:@"revoke" options:NSCaseInsensitiveSearch].location != NSNotFound;
	BOOL recalled = LxIsRecalledChatData(msgData) || msgState == 6 || msgState == 7 || builderLooksRevoke;
	LxTrackRecalledChatData(msgData, recalled);
	LxLogLine(@"layoutUI self=%p msgData=%p state=%d recalled=%d parent=%@ builder=%@",
	          self, msgData, msgState, recalled ? 1 : 0, LxClassName(parentView), builderName);

	UIView *bubbleView = (UIView *)LxObjcMsgSendId(self, @selector(contentView));
	if (![bubbleView isKindOfClass:[UIView class]]) {
		LxLogLine(@"layoutUI skip invalid contentView self=%p contentView=%p", self, bubbleView);
		return result;
	}

	UILabel *badge = (UILabel *)[bubbleView viewWithTag:kLxRecalledBadgeTag];
	if (!recalled) {
		[badge removeFromSuperview];
		LxLogLine(@"badge remove self=%p msgData=%p", self, msgData);
		return result;
	}

	if (!badge) {
		badge = [[UILabel alloc] initWithFrame:CGRectZero];
		badge.tag = kLxRecalledBadgeTag;
		badge.text = @"已撤回";
		badge.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
		badge.textColor = [UIColor whiteColor];
		badge.textAlignment = NSTextAlignmentCenter;
		badge.backgroundColor = [UIColor colorWithRed:0.93 green:0.26 blue:0.22 alpha:0.95];
		badge.layer.cornerRadius = 8.0;
		badge.layer.masksToBounds = YES;
		[bubbleView addSubview:badge];
		LxLogLine(@"badge add self=%p msgData=%p bubble=%p", self, msgData, bubbleView);
	}

	[bubbleView bringSubviewToFront:badge];
	[badge sizeToFit];
	CGFloat padX = 6.0;
	CGFloat padY = 2.0;
	CGFloat badgeW = MAX(40.0, CGRectGetWidth(badge.bounds) + padX * 2.0);
	CGFloat badgeH = MAX(16.0, CGRectGetHeight(badge.bounds) + padY * 2.0);
	CGFloat x = MAX(2.0, CGRectGetWidth(bubbleView.bounds) - badgeW - 6.0);
	badge.frame = CGRectMake(x, 4.0, badgeW, badgeH);
	LxLogLine(@"badge update self=%p msgData=%p frame={%.1f,%.1f,%.1f,%.1f}", self, msgData, badge.frame.origin.x, badge.frame.origin.y, badge.frame.size.width, badge.frame.size.height);
	return result;
}

%end

%hook sub_1000010100215832

+ (BOOL)sub_1000010100215833 {
	return NO;
}

+ (BOOL)sub_1000010100215834 {
	return NO;
}

+ (BOOL)sub_1000010100215837 {
	return NO;
}

%end

%hook sub_2105813100215866

+ (BOOL)autoCheck {
	return NO;
}

%end

%hook sub_1000010100215866

+ (BOOL)sub_1000010100215867:(id)arg1 {
	return NO;
}

%end

%hook sub_3108813100215323

+ (void)autocheck {
}

+ (void)checkRoot {
}

%end

%hook CoreMessUtils

+ (BOOL)isJailBreak {
	return NO;
}

+ (BOOL)isJailBreak1 {
	return NO;
}

+ (BOOL)isJailBreak2 {
	return NO;
}

+ (BOOL)isJailBreak3 {
	return NO;
}

+ (BOOL)isJailBreak4 {
	return NO;
}

+ (BOOL)isJailBreak5 {
	return NO;
}

+ (BOOL)isJailBreak6 {
	return NO;
}

+ (BOOL)isJailBreak7 {
	return NO;
}

+ (BOOL)isJailBreak8 {
	return NO;
}

%end
