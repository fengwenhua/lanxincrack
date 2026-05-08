#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <limits.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

#ifndef LX_BUILD_ID
#define LX_BUILD_ID @"dev"
#endif

static const NSInteger kLxRecalledBadgeTag = 0x4C585245; // "LXRE"
static const NSInteger kLxHistoryRecalledBadgeTag = 0x4C584852; // "LXHR"
static const NSInteger kLxGenericRecalledBadgeTag = 0x4C584743; // "LXGC"
static const void *kLxRecalledFlagKey = &kLxRecalledFlagKey;
static const void *kLxChatBadgeKnownRecalledStateKey = &kLxChatBadgeKnownRecalledStateKey;
static const void *kLxChatBadgePendingStateKey = &kLxChatBadgePendingStateKey;
static const void *kLxChatBadgePendingCountKey = &kLxChatBadgePendingCountKey;
static const void *kLxChatBadgeLastPositiveTsKey = &kLxChatBadgeLastPositiveTsKey;
static const void *kLxChatBadgeLastSourcePathKey = &kLxChatBadgeLastSourcePathKey;
static const void *kLxChatBadgeVisibleKey = &kLxChatBadgeVisibleKey;
static const void *kLxChatBadgeLockedSideKnownKey = &kLxChatBadgeLockedSideKnownKey;
static const void *kLxChatBadgeLockedSideValueKey = &kLxChatBadgeLockedSideValueKey;
static const void *kLxChatBadgeLastAnchorRectKey = &kLxChatBadgeLastAnchorRectKey;
static const void *kLxChatBadgeLastFrameKey = &kLxChatBadgeLastFrameKey;
static const void *kLxChatBadgeLastSideKey = &kLxChatBadgeLastSideKey;
static NSString *const kLXBuildID = LX_BUILD_ID;
static NSString *const kLxRecalledBadgeText = @"[撤]";

static NSString *LxPrimaryLogPath(void) {
	return [NSHomeDirectory() stringByAppendingPathComponent:
	        [NSString stringWithFormat:@"Library/Caches/lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

static NSString *LxFallbackLogPath(void) {
	NSString *tmp = NSTemporaryDirectory();
	if (tmp.length == 0) {
		tmp = @"/tmp";
	}
	return [tmp stringByAppendingPathComponent:
	        [NSString stringWithFormat:@"lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

static NSString *LxBuildIDPath(void) {
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/lanxincrack.buildid"];
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

static inline int LxObjcMsgSendInt(id target, SEL selector, int defaultValue) {
	if (!target || !selector) return defaultValue;
	if (![target respondsToSelector:selector]) return defaultValue;
	return ((int (*)(id, SEL))objc_msgSend)(target, selector);
}

static inline long long LxObjcMsgSendLongLong(id target, SEL selector, long long defaultValue) {
	if (!target || !selector) return defaultValue;
	if (![target respondsToSelector:selector]) return defaultValue;
	return ((long long (*)(id, SEL))objc_msgSend)(target, selector);
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

static NSMapTable *LxRecalledChatDataLogStateMap(void) {
	static NSMapTable *map = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		map = [NSMapTable weakToStrongObjectsMapTable];
	});
	return map;
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
	NSMapTable *map = LxRecalledChatDataLogStateMap();
	BOOL shouldLog = YES;
	@synchronized (map) {
		NSNumber *last = [map objectForKey:chatData];
		if (last && last.boolValue == recalled) {
			shouldLog = NO;
		}
		[map setObject:@(recalled) forKey:chatData];
	}
	if (shouldLog) {
		static int trackLogCount = 0;
		if (trackLogCount < 100) {
			trackLogCount++;
			LxLogLine(@"track chatData=%p recalled=%d", chatData, recalled ? 1 : 0);
		}
	}
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

static NSString *LxNormalizeScalarObject(id value) {
	if (!value) return nil;
	if ([value isKindOfClass:[NSString class]]) {
		NSString *s = (NSString *)value;
		return s.length > 0 ? s : nil;
	}
	if ([value isKindOfClass:[NSNumber class]]) {
		return [(NSNumber *)value stringValue];
	}
	if ([value respondsToSelector:@selector(UUIDString)]) {
		id uuid = LxObjcMsgSendId(value, @selector(UUIDString));
		if ([uuid isKindOfClass:[NSString class]] && ((NSString *)uuid).length > 0) return uuid;
	}
	if ([value respondsToSelector:@selector(stringValue)]) {
		id sv = LxObjcMsgSendId(value, @selector(stringValue));
		if ([sv isKindOfClass:[NSString class]] && ((NSString *)sv).length > 0) return sv;
	}
	return nil;
}

static NSString *LxExtractKeyPartFromObject(id obj, int depth) {
	if (!obj || depth <= 0) return nil;
	NSString *direct = LxNormalizeScalarObject(obj);
	if (direct.length > 0) return direct;

	static NSArray<NSString *> *objSelectors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		objSelectors = @[
			@"msgId", @"messageId", @"coreMessageId", @"uuid", @"serverMsgId", @"localMsgId",
			@"value", @"identifier", @"messageIdentifier", @"msgIdentifier", @"localUUID"
		];
	});
	for (NSString *name in objSelectors) {
		id nested = LxObjcMsgSendId(obj, NSSelectorFromString(name));
		NSString *part = LxExtractKeyPartFromObject(nested, depth - 1);
		if (part.length > 0) {
			return [NSString stringWithFormat:@"%@.%@=%@", LxClassName(obj), name, part];
		}
	}

	static NSArray<NSString *> *intSelectors;
	static dispatch_once_t onceToken2;
	dispatch_once(&onceToken2, ^{
		intSelectors = @[
			@"sequence", @"msgSeq", @"localSeq", @"referSequence", @"sequenceId",
			@"serverVersionSequence", @"localId", @"mid", @"value"
		];
	});
	for (NSString *name in intSelectors) {
		long long n = LxObjcMsgSendLongLong(obj, NSSelectorFromString(name), LLONG_MIN);
		if (n != LLONG_MIN && n > 0) {
			return [NSString stringWithFormat:@"%@.%@=%lld", LxClassName(obj), name, n];
		}
	}

	return nil;
}

static NSString *LxMessageKeyFromObject(id obj) {
	if (!obj) return nil;

	static NSArray<NSString *> *objSelectors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		objSelectors = @[@"msgId", @"messageId", @"coreMessageId", @"uuid", @"serverMsgId", @"localMsgId", @"localUUID"];
	});

	for (NSString *name in objSelectors) {
		SEL sel = NSSelectorFromString(name);
		id value = LxObjcMsgSendId(obj, sel);
		NSString *part = LxExtractKeyPartFromObject(value, 2);
		if (part.length > 0) {
			return [NSString stringWithFormat:@"%@:%@", name, part];
		}
	}

	static NSArray<NSString *> *intSelectors;
	static dispatch_once_t onceToken2;
	dispatch_once(&onceToken2, ^{
		intSelectors = @[@"sequence", @"msgSeq", @"localSeq", @"referSequence", @"sequenceId", @"serverVersionSequence"];
	});

	for (NSString *name in intSelectors) {
		SEL sel = NSSelectorFromString(name);
		if (![obj respondsToSelector:sel]) continue;
		long long n = LxObjcMsgSendLongLong(obj, sel, LLONG_MIN);
		if (n != LLONG_MIN && n > 0) {
			return [NSString stringWithFormat:@"%@:%lld", name, n];
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

static BOOL LxShouldLogDeepHitForObject(id obj) {
	if (!obj) return NO;
	static NSHashTable *seen = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		seen = [NSHashTable weakObjectsHashTable];
	});
	@synchronized (seen) {
		if ([seen containsObject:obj]) return NO;
		[seen addObject:obj];
		return YES;
	}
}

static id LxFindRecalledInnerMessageObjectWithSeen(id obj, NSInteger depth, NSHashTable *seen) {
	if (!obj || depth <= 0) return nil;
	if (!seen) return nil;
	@synchronized (seen) {
		if ([seen containsObject:obj]) return nil;
		[seen addObject:obj];
	}
	static NSArray<NSString *> *selectors = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		selectors = @[
			@"msgModel", @"data", @"chatData", @"message", @"msgData",
			@"coreMessage", @"messageModel", @"model", @"object", @"item",
			@"cellItem", @"cellitem", @"elementModel", @"viewModel"
		];
	});
	for (NSString *name in selectors) {
		id nested = LxObjcMsgSendId(obj, NSSelectorFromString(name));
		if (!nested || nested == obj) continue;
		if (LxIsRecalledMessageObject(nested)) return nested;
		id found = LxFindRecalledInnerMessageObjectWithSeen(nested, depth - 1, seen);
		if (found) return found;
	}
	return nil;
}

static id LxFindRecalledInnerMessageObject(id obj, NSInteger depth) {
	if (!obj || depth <= 0) return nil;
	NSHashTable *seen = [NSHashTable weakObjectsHashTable];
	return LxFindRecalledInnerMessageObjectWithSeen(obj, depth, seen);
}

static BOOL LxIsRecalledMessageObjectDeep(id obj) {
	if (!obj) return NO;
	if (LxIsRecalledMessageObject(obj)) return YES;
	id inner = LxFindRecalledInnerMessageObject(obj, 4);
	if (!inner) return NO;
	LxTrackRecalledChatData(obj, YES);
	if (LxShouldLogDeepHitForObject(obj)) {
		LxLogLine(@"[LXPATCH] deep recalled hit wrapper=%p wrapperClass=%@ inner=%p innerClass=%@",
		          obj, LxClassName(obj), inner, LxClassName(inner));
	}
	return YES;
}

static NSString *LxResponderViewControllerName(UIView *view) {
	if (![view isKindOfClass:[UIView class]]) return @"(nil)";
	UIResponder *resp = view;
	while (resp) {
		resp = resp.nextResponder;
		if ([resp isKindOfClass:[UIViewController class]]) {
			return NSStringFromClass([resp class]);
		}
	}
	return @"(none)";
}

static id LxDiagnosticCandidateFromObject(id obj, NSString **outSelector) {
	if (outSelector) *outSelector = nil;
	if (!obj) return nil;
	static NSArray<NSString *> *selectors = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		selectors = @[
			@"chatEx", @"modelChatEx", @"msgData", @"chatData", @"msgModel",
			@"message", @"data", @"model", @"item", @"cellitem", @"cellItem", @"elementModel",
			@"messageModel", @"viewModel", @"object", @"entity", @"record", @"imMessage"
		];
	});
	for (NSString *name in selectors) {
		id value = LxObjcMsgSendId(obj, NSSelectorFromString(name));
		if (!value || value == obj) continue;
		if (outSelector) *outSelector = name;
		return value;
	}
	return nil;
}

static BOOL LxIsSingleChatViewContext(UIView *view) {
	if (![view isKindOfClass:[UIView class]]) return NO;
	NSString *vc = LxResponderViewControllerName(view);
	return [vc isEqualToString:@"LxSingleChatViewController"] || [vc isEqualToString:@"LxGroupChatViewController"];
}

static BOOL LxIsChatMsgCellObject(id cell) {
	if (!cell) return NO;
	return [LxClassName(cell) isEqualToString:@"LxChatMsgCell"];
}

static BOOL LxLooksLikeMessageCarrierObject(id obj) {
	if (!obj) return NO;
	NSString *name = LxClassName(obj);
	if ([name hasPrefix:@"IM"] || [name rangeOfString:@"Message"].location != NSNotFound || [name rangeOfString:@"Chat"].location != NSNotFound) {
		return YES;
	}
	if ([obj respondsToSelector:@selector(msgState)] || [obj respondsToSelector:@selector(messageContent)] || [obj respondsToSelector:@selector(text)]) {
		return YES;
	}
	return NO;
}

static BOOL LxInterestingName(NSString *name) {
	if (name.length == 0) return NO;
	NSString *lower = name.lowercaseString;
	return ([lower containsString:@"msg"] ||
	        [lower containsString:@"chat"] ||
	        [lower containsString:@"data"] ||
	        [lower containsString:@"model"] ||
	        [lower containsString:@"item"] ||
	        [lower containsString:@"content"] ||
	        [lower containsString:@"message"] ||
	        [lower containsString:@"record"]);
}

static BOOL LxShouldLogChatBindMiss(void) {
	static int count = 0;
	if (count >= 120) return NO;
	count++;
	return YES;
}

static NSMapTable *LxChatMsgCellPathMap(void) {
	static NSMapTable *map = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		map = [NSMapTable strongToStrongObjectsMapTable];
	});
	return map;
}

typedef NS_ENUM(NSInteger, LxChatRecalledState) {
	LxChatRecalledStateUnknown = -1,
	LxChatRecalledStateNotRecalled = 0,
	LxChatRecalledStateRecalled = 1,
};

static Ivar LxFindObjectIvar(Class cls, NSString *ivarName) {
	if (!cls || ivarName.length == 0) return NULL;
	for (Class cur = cls; cur; cur = class_getSuperclass(cur)) {
		Ivar iv = class_getInstanceVariable(cur, ivarName.UTF8String);
		if (!iv) continue;
		const char *enc = ivar_getTypeEncoding(iv);
		if (enc && enc[0] == '@') return iv;
	}
	return NULL;
}

static id LxReadObjectIvar(id obj, NSString *ivarName) {
	if (!obj || ivarName.length == 0) return nil;
	Ivar iv = LxFindObjectIvar([obj class], ivarName);
	if (!iv) return nil;
	return object_getIvar(obj, iv);
}

static BOOL LxSelectorReturnsObjectNoArg(id obj, SEL sel) {
	if (!obj || !sel) return NO;
	Method m = class_getInstanceMethod([obj class], sel);
	if (!m) return NO;
	if (method_getNumberOfArguments(m) != 2) return NO;
	char retType[16] = {0};
	method_getReturnType(m, retType, sizeof(retType));
	return retType[0] == '@';
}

static id LxReadObjectBySelector(id obj, NSString *selName) {
	if (!obj || selName.length == 0) return nil;
	SEL sel = NSSelectorFromString(selName);
	if (!sel || ![obj respondsToSelector:sel]) return nil;
	if (!LxSelectorReturnsObjectNoArg(obj, sel)) return nil;
	return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static LxChatRecalledState LxTryPathForChatMsgCell(id cell, NSString *path, id *outTarget) {
	if (outTarget) *outTarget = nil;
	if (!cell || path.length == 0) return LxChatRecalledStateUnknown;

	id value = nil;
	if ([path hasPrefix:@"ivar:"]) {
		value = LxReadObjectIvar(cell, [path substringFromIndex:5]);
	} else if ([path hasPrefix:@"sel:"]) {
		value = LxReadObjectBySelector(cell, [path substringFromIndex:4]);
	}
	if (!value) return LxChatRecalledStateUnknown;
	if (outTarget) *outTarget = value;
	if (LxIsRecalledMessageObjectDeep(value)) return LxChatRecalledStateRecalled;
	if (LxLooksLikeMessageCarrierObject(value)) return LxChatRecalledStateNotRecalled;
	return LxChatRecalledStateUnknown;
}

static LxChatRecalledState LxScanChatMsgCellForRecalled(id cell, NSString **outPath, id *outTarget) {
	if (outPath) *outPath = nil;
	if (outTarget) *outTarget = nil;
	if (!cell) return LxChatRecalledStateUnknown;

	static NSArray<NSString *> *preferredIvars = nil;
	static NSArray<NSString *> *preferredSelectors = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		preferredIvars = @[
			@"msg", @"chatDataWhenTouchBegin", @"chatData", @"templateContent",
			@"_chatEx", @"_msgData", @"_chatData", @"_msgModel", @"_message", @"_data", @"_model",
			@"_item", @"_cellItem", @"_elementModel", @"_record", @"_imMessage"
		];
		preferredSelectors = @[
			@"msg", @"chatDataWhenTouchBegin", @"chatData", @"templateContent",
			@"chatEx", @"msgData", @"msgModel", @"message", @"data", @"model", @"item",
			@"cellItem", @"elementModel", @"record", @"imMessage", @"messageModel", @"viewModel"
		];
	});

	NSString *className = LxClassName(cell);
	NSMapTable *pathMap = LxChatMsgCellPathMap();
	BOOL sawCarrier = NO;
	NSString *cachedPath = nil;
	@synchronized (pathMap) {
		cachedPath = [pathMap objectForKey:className];
	}
	if (cachedPath.length > 0) {
		id target = nil;
		LxChatRecalledState cachedState = LxTryPathForChatMsgCell(cell, cachedPath, &target);
		if (cachedState == LxChatRecalledStateRecalled) {
			if (outPath) *outPath = cachedPath;
			if (outTarget) *outTarget = target;
			return LxChatRecalledStateRecalled;
		}
		if (cachedState == LxChatRecalledStateNotRecalled) {
			if (outPath) *outPath = cachedPath;
			if (outTarget) *outTarget = target;
			sawCarrier = YES;
		}
	}

	for (NSString *name in preferredIvars) {
		id value = LxReadObjectIvar(cell, name);
		if (!value) continue;
		NSString *path = [@"ivar:" stringByAppendingString:name];
		if (LxLooksLikeMessageCarrierObject(value)) {
			sawCarrier = YES;
			@synchronized (pathMap) {
				[pathMap setObject:path forKey:className];
			}
		}
		if (LxIsRecalledMessageObjectDeep(value)) {
			if (outPath) *outPath = path;
			if (outTarget) *outTarget = value;
			return LxChatRecalledStateRecalled;
		}
	}

	for (NSString *selName in preferredSelectors) {
		id value = LxReadObjectBySelector(cell, selName);
		if (!value) continue;
		NSString *path = [@"sel:" stringByAppendingString:selName];
		if (LxLooksLikeMessageCarrierObject(value)) {
			sawCarrier = YES;
			@synchronized (pathMap) {
				[pathMap setObject:path forKey:className];
			}
		}
		if (LxIsRecalledMessageObjectDeep(value)) {
			if (outPath) *outPath = path;
			if (outTarget) *outTarget = value;
			return LxChatRecalledStateRecalled;
		}
	}

	// Fallback: enumerate all object ivars with interesting names.
	NSMutableSet<NSString *> *seenIvarNames = [NSMutableSet set];
	for (Class cur = [cell class]; cur; cur = class_getSuperclass(cur)) {
		unsigned ivarCount = 0;
		Ivar *ivars = class_copyIvarList(cur, &ivarCount);
		for (unsigned i = 0; i < ivarCount; i++) {
			Ivar iv = ivars[i];
			const char *enc = ivar_getTypeEncoding(iv);
			if (!enc || enc[0] != '@') continue;
			const char *cname = ivar_getName(iv);
			if (!cname) continue;
			NSString *name = [NSString stringWithUTF8String:cname];
			if (name.length == 0 || [seenIvarNames containsObject:name]) continue;
			[seenIvarNames addObject:name];
			if (!LxInterestingName(name)) continue;

			id value = object_getIvar(cell, iv);
			if (!value) continue;
			NSString *path = [@"ivar:" stringByAppendingString:name];
			if (LxLooksLikeMessageCarrierObject(value)) {
				sawCarrier = YES;
				@synchronized (pathMap) {
					[pathMap setObject:path forKey:className];
				}
			}
			if (LxIsRecalledMessageObjectDeep(value)) {
				if (outPath) *outPath = path;
				if (outTarget) *outTarget = value;
				if (ivars) free(ivars);
				return LxChatRecalledStateRecalled;
			}
		}
		if (ivars) free(ivars);
	}

	if (sawCarrier) return LxChatRecalledStateNotRecalled;

	if (LxShouldLogChatBindMiss()) {
		NSNumber *last = objc_getAssociatedObject(cell, kLxChatBadgeKnownRecalledStateKey);
		LxLogLine(@"[LXPATCH] chat-cell-bind-miss cell=%p class=%@ lastKnown=%@",
		          cell, className, last ?: @"(nil)");
	}

	return LxChatRecalledStateUnknown;
}

static LxChatRecalledState LxChatMsgCellRecalledState(id cell, id *outTarget, NSString **outPath) {
	if (outTarget) *outTarget = nil;
	if (outPath) *outPath = @"(none)";
	if (!LxIsChatMsgCellObject(cell)) return LxChatRecalledStateUnknown;
	if (!LxIsSingleChatViewContext((UIView *)cell)) return LxChatRecalledStateUnknown;

	NSString *path = nil;
	id target = nil;
	LxChatRecalledState state = LxScanChatMsgCellForRecalled(cell, &path, &target);
	if (outTarget) *outTarget = target;
	if (outPath) *outPath = path ?: @"(none)";
	return state;
}

static BOOL LxShouldLogGenericBadge(void) {
	static int count = 0;
	if (count >= 160) return NO;
	count++;
	return YES;
}

static BOOL LxShouldLogUnknownSideSkip(void) {
	static int count = 0;
	if (count >= 80) return NO;
	count++;
	return YES;
}

static BOOL LxReadBoolBySelector(id obj, NSString *selName, BOOL *ok) {
	if (ok) *ok = NO;
	if (!obj || selName.length == 0) return NO;
	SEL sel = NSSelectorFromString(selName);
	if (!sel || ![obj respondsToSelector:sel]) return NO;
	Method m = class_getInstanceMethod([obj class], sel);
	if (!m || method_getNumberOfArguments(m) != 2) return NO;
	char retType[16] = {0};
	method_getReturnType(m, retType, sizeof(retType));
	BOOL value = NO;
	switch (retType[0]) {
		case 'B':
		case 'c':
			value = ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
			if (ok) *ok = YES;
			return value;
		case 'i':
		case 's':
		case 'l':
		case 'q':
		case 'I':
		case 'S':
		case 'L':
		case 'Q': {
			long long n = ((long long (*)(id, SEL))objc_msgSend)(obj, sel);
			if (ok) *ok = YES;
			return n != 0;
		}
		default:
			return NO;
	}
}

static BOOL LxChatMessageFromSelfByObject(id obj, BOOL *known) {
	if (known) *known = NO;
	if (!obj) return NO;
	static NSArray<NSString *> *boolSelectors = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		boolSelectors = @[
			@"isSelf", @"isSelfMsg", @"isSenderSelf", @"isSendBySelf", @"isSendByMe",
			@"fromSelf", @"isFromSelf", @"isFromMe", @"isMine", @"sendByMe",
			@"isOutgoing", @"outgoing"
		];
	});
	for (NSString *name in boolSelectors) {
		BOOL ok = NO;
		BOOL val = LxReadBoolBySelector(obj, name, &ok);
		if (!ok) continue;
		if (known) *known = YES;
		return val;
	}
	return NO;
}

static BOOL LxChatMessageFromSelf(id cell, id target, BOOL *known) {
	if (known) *known = NO;
	BOOL localKnown = NO;
	BOOL val = LxChatMessageFromSelfByObject(target, &localKnown);
	if (localKnown) {
		if (known) *known = YES;
		return val;
	}

	id current = target;
	for (NSInteger i = 0; i < 3 && current; i++) {
		NSString *unusedSel = nil;
		current = LxDiagnosticCandidateFromObject(current, &unusedSel);
		if (!current) break;
		val = LxChatMessageFromSelfByObject(current, &localKnown);
		if (localKnown) {
			if (known) *known = YES;
			return val;
		}
	}

	id model = LxReadObjectIvar(cell, @"msg");
	val = LxChatMessageFromSelfByObject(model, &localKnown);
	if (localKnown) {
		if (known) *known = YES;
		return val;
	}

	static NSArray<NSString *> *cellIvars = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		cellIvars = @[@"chatDataWhenTouchBegin", @"chatData", @"templateContent"];
	});
	for (NSString *name in cellIvars) {
		id obj = LxReadObjectIvar(cell, name);
		val = LxChatMessageFromSelfByObject(obj, &localKnown);
		if (localKnown) {
			if (known) *known = YES;
			return val;
		}
	}
	return NO;
}

static void LxCollectBubbleCandidates(UIView *root, UIView *contentView, NSMutableArray<UIView *> *out, NSInteger depth) {
	if (![root isKindOfClass:[UIView class]] || depth < 0) return;
	for (UIView *sub in root.subviews) {
		if (![sub isKindOfClass:[UIView class]]) continue;
		if (sub.hidden || sub.alpha < 0.05) continue;
		if (sub.tag == kLxGenericRecalledBadgeTag) continue;

		CGRect rect = [contentView convertRect:sub.bounds fromView:sub];
		CGFloat w = CGRectGetWidth(rect);
		CGFloat h = CGRectGetHeight(rect);
		CGFloat cw = CGRectGetWidth(contentView.bounds);
		CGFloat ch = CGRectGetHeight(contentView.bounds);
		BOOL sizeOK = (w >= 44.0 && h >= 20.0 && w <= MAX(cw, 44.0) && h <= MAX(ch, 20.0));
		BOOL notFullCover = !(w > cw * 0.97 && h > ch * 0.90);
		if (sizeOK && notFullCover) {
			[out addObject:sub];
		}

		if (depth > 0) {
			LxCollectBubbleCandidates(sub, contentView, out, depth - 1);
		}
	}
}

static CGRect LxChatBubbleAnchorRect(id cell, UIView *contentView, BOOL fromSelfKnown, BOOL fromSelf) {
	if (![contentView isKindOfClass:[UIView class]]) return contentView.bounds;
	NSMutableArray<UIView *> *candidates = [NSMutableArray array];
	LxCollectBubbleCandidates(contentView, contentView, candidates, 2);
	if (candidates.count == 0) return contentView.bounds;

	CGFloat midX = CGRectGetMidX(contentView.bounds);
	NSValue *lastAnchorValue = objc_getAssociatedObject(cell, kLxChatBadgeLastAnchorRectKey);
	CGRect lastAnchor = lastAnchorValue ? [lastAnchorValue CGRectValue] : CGRectZero;
	BOOL hasLastAnchor = lastAnchorValue != nil;
	UIView *best = nil;
	double bestScore = -DBL_MAX;
	for (UIView *v in candidates) {
		CGRect r = [contentView convertRect:v.bounds fromView:v];
		double score = CGRectGetWidth(r) * CGRectGetHeight(r);
		NSString *cls = LxClassName(v).lowercaseString;
		if ([cls containsString:@"bubble"] || [cls containsString:@"content"] || [cls containsString:@"msg"]) {
			score += 50000.0;
		}
		if (CGRectGetWidth(r) > CGRectGetWidth(contentView.bounds) * 0.90) {
			score -= 20000.0;
		}
		if (fromSelfKnown) {
			double bias = CGRectGetMidX(r) - midX;
			score += fromSelf ? (bias * 120.0) : (-bias * 120.0);
		}
		BOOL better = (score > bestScore + 1.0);
		if (!better && fabs(score - bestScore) <= 1.0 && hasLastAnchor && best) {
			CGFloat dNew = fabs(CGRectGetMidX(r) - CGRectGetMidX(lastAnchor)) + fabs(CGRectGetMidY(r) - CGRectGetMidY(lastAnchor));
			CGRect bestRect = [contentView convertRect:best.bounds fromView:best];
			CGFloat dOld = fabs(CGRectGetMidX(bestRect) - CGRectGetMidX(lastAnchor)) + fabs(CGRectGetMidY(bestRect) - CGRectGetMidY(lastAnchor));
			better = (dNew < dOld);
		}
		if (better || best == nil) {
			bestScore = score;
			best = v;
		}
	}

	if (!best) return contentView.bounds;
	return [contentView convertRect:best.bounds fromView:best];
}

static void LxUpdateChatMsgCellBadge(id cell, NSString *reason) {
	if (![cell isKindOfClass:[UIView class]]) return;
	if (!LxIsChatMsgCellObject(cell)) return;
	if (!LxIsSingleChatViewContext((UIView *)cell)) return;

	UIView *contentView = (UIView *)LxObjcMsgSendId(cell, @selector(contentView));
	if (![contentView isKindOfClass:[UIView class]]) return;

	id target = nil;
	NSString *path = nil;
	LxChatRecalledState state = LxChatMsgCellRecalledState(cell, &target, &path);
	BOOL fromSelfKnown = NO;
	BOOL fromSelf = LxChatMessageFromSelf(cell, target, &fromSelfKnown);
	NSString *sideSource = @"model";
	NSNumber *lockedSideKnownNum = objc_getAssociatedObject(cell, kLxChatBadgeLockedSideKnownKey);
	NSNumber *lockedSideValueNum = objc_getAssociatedObject(cell, kLxChatBadgeLockedSideValueKey);
	BOOL lockedSideKnown = lockedSideKnownNum.boolValue;
	if (lockedSideKnown) {
		fromSelfKnown = YES;
		fromSelf = lockedSideValueNum.boolValue;
		sideSource = @"locked";
	} else if (fromSelfKnown) {
		objc_setAssociatedObject(cell, kLxChatBadgeLockedSideKnownKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kLxChatBadgeLockedSideValueKey, @(fromSelf), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		sideSource = @"model";
	}

	UILabel *badge = (UILabel *)[contentView viewWithTag:kLxGenericRecalledBadgeTag];
	NSNumber *known = objc_getAssociatedObject(cell, kLxChatBadgeKnownRecalledStateKey);
	BOOL knownRecalled = known.boolValue;
	NSNumber *visibleNum = objc_getAssociatedObject(cell, kLxChatBadgeVisibleKey);
	BOOL visible = visibleNum ? visibleNum.boolValue : (badge != nil);
	NSNumber *pendingStateNum = objc_getAssociatedObject(cell, kLxChatBadgePendingStateKey);
	NSNumber *pendingCountNum = objc_getAssociatedObject(cell, kLxChatBadgePendingCountKey);
	NSInteger pendingState = pendingStateNum ? pendingStateNum.integerValue : LxChatRecalledStateUnknown;
	NSInteger pendingCount = pendingCountNum ? pendingCountNum.integerValue : 0;
	NSNumber *lastPositiveTsNum = objc_getAssociatedObject(cell, kLxChatBadgeLastPositiveTsKey);
	NSTimeInterval lastPositiveTs = lastPositiveTsNum ? lastPositiveTsNum.doubleValue : 0;
	NSString *lastSourcePath = objc_getAssociatedObject(cell, kLxChatBadgeLastSourcePathKey);

	if (state == LxChatRecalledStateUnknown) {
		return;
	}

	if (state == LxChatRecalledStateNotRecalled) {
		if (pendingState == LxChatRecalledStateNotRecalled) {
			pendingCount += 1;
		} else {
			pendingState = LxChatRecalledStateNotRecalled;
			pendingCount = 1;
		}
		objc_setAssociatedObject(cell, kLxChatBadgePendingStateKey, @(pendingState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kLxChatBadgePendingCountKey, @(pendingCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
		double ageMs = (lastPositiveTs > 0) ? ((now - lastPositiveTs) * 1000.0) : DBL_MAX;
		BOOL sameSource = (lastSourcePath.length == 0 || [lastSourcePath isEqualToString:(path ?: @"(none)")]);
		BOOL shouldRemove = (pendingCount >= 4 && ageMs >= 350.0 && sameSource);
		if (!shouldRemove) {
			return;
		}

		objc_setAssociatedObject(cell, kLxChatBadgeKnownRecalledStateKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kLxChatBadgePendingStateKey, @(LxChatRecalledStateUnknown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kLxChatBadgePendingCountKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kLxChatBadgeVisibleKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (badge) {
			[badge removeFromSuperview];
			if (LxShouldLogGenericBadge()) {
				LxLogLine(@"[LXPATCH] chat badge remove cell=%@ ptr=%p reason=%@ path=%@ negStreak=%ld ageMs=%.1f",
				          LxClassName(cell), cell, reason ?: @"(nil)", path ?: @"(none)", (long)pendingCount, ageMs);
			}
		}
		return;
	}

	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	objc_setAssociatedObject(cell, kLxChatBadgeKnownRecalledStateKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(cell, kLxChatBadgePendingStateKey, @(LxChatRecalledStateUnknown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(cell, kLxChatBadgePendingCountKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(cell, kLxChatBadgeLastPositiveTsKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(cell, kLxChatBadgeLastSourcePathKey, path ?: @"(none)", OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	if (!fromSelfKnown) {
		CGRect guessAnchor = LxChatBubbleAnchorRect(cell, contentView, NO, NO);
		CGFloat delta = CGRectGetMidX(guessAnchor) - CGRectGetMidX(contentView.bounds);
		if (fabs(delta) >= 1.0) {
			fromSelf = (delta > 0);
			fromSelfKnown = YES;
			sideSource = @"geometry";
			objc_setAssociatedObject(cell, kLxChatBadgeLockedSideKnownKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(cell, kLxChatBadgeLockedSideValueKey, @(fromSelf), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		} else {
			NSString *lastSide = objc_getAssociatedObject(cell, kLxChatBadgeLastSideKey);
			if ([lastSide isEqualToString:@"self"] || [lastSide isEqualToString:@"other"]) {
				fromSelf = [lastSide isEqualToString:@"self"];
				fromSelfKnown = YES;
				sideSource = @"last";
			}
		}
		if (!fromSelfKnown && LxShouldLogUnknownSideSkip()) {
			LxLogLine(@"[LXPATCH] chat badge skip-unknown-side cell=%@ ptr=%p reason=%@ path=%@ target=%@",
			          LxClassName(cell), cell, reason ?: @"(nil)", path ?: @"(none)", LxClassName(target));
		}
		if (!fromSelfKnown && badge) {
			objc_setAssociatedObject(cell, kLxChatBadgeVisibleKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			return;
		}
	}

	objc_setAssociatedObject(cell, kLxChatBadgeVisibleKey, @(fromSelfKnown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if (!fromSelfKnown) return;

	BOOL wasHidden = (badge == nil || !visible || !knownRecalled);
	if (!badge) {
		badge = [[UILabel alloc] initWithFrame:CGRectZero];
		badge.tag = kLxGenericRecalledBadgeTag;
		badge.text = kLxRecalledBadgeText;
		badge.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
		badge.textColor = [UIColor whiteColor];
		badge.textAlignment = NSTextAlignmentCenter;
		badge.backgroundColor = [UIColor colorWithRed:0.93 green:0.20 blue:0.18 alpha:0.98];
		badge.layer.cornerRadius = 8.0;
		badge.layer.masksToBounds = YES;
		badge.userInteractionEnabled = NO;
		[contentView addSubview:badge];
	}
	[contentView bringSubviewToFront:badge];
	badge.text = kLxRecalledBadgeText;
	[badge sizeToFit];
	CGFloat badgeW = MAX(34.0, CGRectGetWidth(badge.bounds) + 10.0);
	CGFloat badgeH = MAX(16.0, CGRectGetHeight(badge.bounds) + 4.0);
	CGRect anchor = LxChatBubbleAnchorRect(cell, contentView, fromSelfKnown, fromSelf);
	objc_setAssociatedObject(cell, kLxChatBadgeLastAnchorRectKey, [NSValue valueWithCGRect:anchor], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	CGFloat contentW = CGRectGetWidth(contentView.bounds);
	CGFloat x = fromSelf ? (CGRectGetMinX(anchor) + 4.0) : (CGRectGetMaxX(anchor) - badgeW - 4.0);
	x = MAX(2.0, MIN(contentW - badgeW - 2.0, x));
	CGFloat y = MAX(2.0, CGRectGetMinY(anchor) + 4.0);
	y = MAX(1.0, y);
	badge.frame = CGRectMake(x, y, badgeW, badgeH);

	BOOL frameChanged = YES;
	NSValue *lastFrameValue = objc_getAssociatedObject(cell, kLxChatBadgeLastFrameKey);
	if (lastFrameValue) {
		CGRect lastFrame = [lastFrameValue CGRectValue];
		frameChanged = (fabs(CGRectGetMinX(lastFrame) - x) > 6.0 ||
		               fabs(CGRectGetMinY(lastFrame) - y) > 6.0 ||
		               fabs(CGRectGetWidth(lastFrame) - badgeW) > 2.0 ||
		               fabs(CGRectGetHeight(lastFrame) - badgeH) > 2.0);
	}
	NSString *sideStr = fromSelf ? @"self" : @"other";
	NSString *lastSide = objc_getAssociatedObject(cell, kLxChatBadgeLastSideKey);
	BOOL sideChanged = ![lastSide isEqualToString:sideStr];

	if ((wasHidden || sideChanged || frameChanged) && LxShouldLogGenericBadge()) {
		LxLogLine(@"[LXPATCH] chat badge show cell=%@ ptr=%p reason=%@ side=%@ known=%d source=%@ place=inside path=%@ target=%@ frame={%.1f,%.1f,%.1f,%.1f}",
		          LxClassName(cell),
		          cell,
		          reason ?: @"(nil)",
		          sideStr,
		          1,
		          sideSource,
		          path ?: @"(none)",
		          LxClassName(target),
		          badge.frame.origin.x, badge.frame.origin.y, badge.frame.size.width, badge.frame.size.height);
	}
	objc_setAssociatedObject(cell, kLxChatBadgeLastFrameKey, [NSValue valueWithCGRect:badge.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(cell, kLxChatBadgeLastSideKey, sideStr, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static BOOL LxShouldLogKeyHitForObject(id obj) {
	if (!obj) return NO;
	static NSHashTable *seen = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		seen = [NSHashTable weakObjectsHashTable];
	});
	@synchronized (seen) {
		if ([seen containsObject:obj]) return NO;
		[seen addObject:obj];
		return YES;
	}
}

static BOOL LxShouldLogHistoryBadgeUpdate(void) {
	static int count = 0;
	if (count >= 160) return NO;
	count++;
	return YES;
}

static void LxUpdateHistoryCellRecalledBadge(id cell, id chatEx, BOOL recalled) {
	if (!cell) return;
	UIView *contentView = (UIView *)LxObjcMsgSendId(cell, @selector(contentView));
	if (![contentView isKindOfClass:[UIView class]]) return;

	UILabel *badge = (UILabel *)[contentView viewWithTag:kLxHistoryRecalledBadgeTag];
	if (!recalled) {
		if (badge) {
			[badge removeFromSuperview];
			if (LxShouldLogHistoryBadgeUpdate()) {
				LxLogLine(@"[LXPATCH] history cell badge remove cell=%p chatEx=%p", cell, chatEx);
			}
		}
		return;
	}

	if (!badge) {
		badge = [[UILabel alloc] initWithFrame:CGRectZero];
		badge.tag = kLxHistoryRecalledBadgeTag;
		badge.text = kLxRecalledBadgeText;
		badge.font = [UIFont boldSystemFontOfSize:11.0];
		badge.textColor = [UIColor whiteColor];
		badge.textAlignment = NSTextAlignmentCenter;
		badge.backgroundColor = [UIColor colorWithRed:0.93 green:0.20 blue:0.18 alpha:0.98];
		badge.layer.cornerRadius = 8.0;
		badge.layer.masksToBounds = YES;
		badge.userInteractionEnabled = NO;
		[contentView addSubview:badge];
		if (LxShouldLogHistoryBadgeUpdate()) {
			LxLogLine(@"[LXPATCH] history cell badge add cell=%p chatEx=%p content=%p", cell, chatEx, contentView);
		}
	}

	[contentView bringSubviewToFront:badge];
	badge.text = kLxRecalledBadgeText;
	[badge sizeToFit];
	CGFloat badgeW = MAX(34.0, CGRectGetWidth(badge.bounds) + 12.0);
	CGFloat badgeH = MAX(18.0, CGRectGetHeight(badge.bounds) + 4.0);
	CGFloat contentW = CGRectGetWidth(contentView.bounds);
	if (contentW < 80.0) {
		contentW = CGRectGetWidth([UIScreen mainScreen].bounds);
	}
	CGFloat x = MAX(8.0, contentW - badgeW - 12.0);
	badge.frame = CGRectMake(x, 6.0, badgeW, badgeH);
	if (LxShouldLogHistoryBadgeUpdate()) {
		LxLogLine(@"[LXPATCH] history cell badge update cell=%p chatEx=%p frame={%.1f,%.1f,%.1f,%.1f}",
		          cell, chatEx, badge.frame.origin.x, badge.frame.origin.y, badge.frame.size.width, badge.frame.size.height);
	}
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
	if (state == 5 && LxIsRecalledMessageByKey(self)) {
		LxTrackRecalledChatData(self, YES);
		if (LxShouldLogKeyHitForObject(self)) {
			LxLogLine(@"[LXPATCH] msgState key-hit self=%p", self);
		}
	}
	if (state == 6 || state == 7) {
		LxTrackRecalledChatData(self, YES);
		LxTrackRecalledMessageKeyIfAny(self);
		LxLogLine(@"[LXPATCH] msgState remap self=%p from=%d to=5", self, state);
		return 5;
	}
	return state;
}

- (void)setMsgState:(int)state {
	if (state == 6 || state == 7) {
		LxLogLine(@"setMsgState self=%p input=%d", self, state);
		LxTrackRecalledChatData(self, YES);
		LxTrackRecalledMessageKeyIfAny(self);
		static int stackDumpCount = 0;
		if (stackDumpCount < 2) {
			stackDumpCount++;
			LxLogLine(@"setMsgState stack=%@", [NSThread callStackSymbols]);
		}
		%orig(5);
		LxLogLine(@"[LXPATCH] setMsgState remap self=%p from=%d to=5", self, state);
		return;
	}
	LxTrackRecalledChatData(self, NO);
	%orig(state);
}

- (id)messageContent {
	id content = %orig;
	if (!LxIsRecalledMessageObject(self)) {
		return content;
	}
	LxTrackRecalledChatData(content, YES);
	LxTrackRecalledMessageKeyIfAny(content);
	return content;
}

%end


%hook LxChatMsgCell

- (void)didMoveToWindow {
	%orig;
	LxUpdateChatMsgCellBadge(self, @"LxChatMsgCell.didMoveToWindow");
}

- (void)layoutSubviews {
	%orig;
	LxUpdateChatMsgCellBadge(self, @"LxChatMsgCell.layoutSubviews");
}

- (void)prepareForReuse {
	%orig;
	UIView *contentView = (UIView *)LxObjcMsgSendId(self, @selector(contentView));
	if ([contentView isKindOfClass:[UIView class]]) {
		UIView *badge = [contentView viewWithTag:kLxGenericRecalledBadgeTag];
		[badge removeFromSuperview];
	}
	objc_setAssociatedObject(self, kLxChatBadgeKnownRecalledStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgePendingStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgePendingCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLastPositiveTsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLastSourcePathKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLockedSideKnownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLockedSideValueKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLastAnchorRectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLastFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kLxChatBadgeLastSideKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%hook LxGroupHistoryTableViewCell

- (void)updateChatEx:(id)chatEx control:(id)control msgListDelegate:(id)msgListDelegate {
	%orig(chatEx, control, msgListDelegate);
	BOOL recalled = LxIsRecalledMessageObjectDeep(chatEx);
	LxUpdateHistoryCellRecalledBadge(self, chatEx, recalled);
}

%end

%hook LxCellSceneGroupRecordHelper

+ (id)builderWithChatData:(id)chatData {
	int state = LxObjcMsgSendInt(chatData, @selector(msgState), -1);
	BOOL recalled = (state == 6 || state == 7);
	if (!recalled && !LxIsRecalledMessageByKey(chatData)) {
		return %orig;
	}
	if (!recalled) recalled = YES;
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
	BOOL recalled = LxIsRecalledMessageObjectDeep(msgData) || msgState == 6 || msgState == 7 || builderLooksRevoke;
	if (!recalled) {
		return result;
	}
	LxTrackRecalledChatData(msgData, recalled);
	LxLogLine(@"layoutUI self=%p msgData=%p state=%d recalled=%d parent=%@ builder=%@",
	          self, msgData, msgState, recalled ? 1 : 0, LxClassName(parentView), builderName);

	UIView *bubbleView = (UIView *)LxObjcMsgSendId(self, @selector(contentView));
	if (![bubbleView isKindOfClass:[UIView class]]) {
		return result;
	}

	UILabel *badge = (UILabel *)[bubbleView viewWithTag:kLxRecalledBadgeTag];
	if (!badge) {
		badge = [[UILabel alloc] initWithFrame:CGRectZero];
		badge.tag = kLxRecalledBadgeTag;
		badge.text = @"撤";
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
	badge.text = @"撤";
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
