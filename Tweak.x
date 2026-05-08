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

static BOOL LxShouldLogDiagLine(void) {
	static int count = 0;
	if (count >= 300) return NO;
	count++;
	return YES;
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

static NSString *LxSuperviewChain(UIView *view, NSInteger maxDepth) {
	if (![view isKindOfClass:[UIView class]]) return @"(nil)";
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	UIView *cur = view;
	for (NSInteger i = 0; cur && i < maxDepth; i++) {
		[parts addObject:NSStringFromClass([cur class]) ?: @"(nil)"];
		cur = cur.superview;
	}
	return [parts componentsJoinedByString:@"<-"];
}

static BOOL LxIsLikelyAppCellClass(id cell) {
	if (!cell) return NO;
	NSString *name = NSStringFromClass([cell class]) ?: @"";
	if (name.length == 0) return NO;
	if ([name hasPrefix:@"_"]) return NO;
	return [name rangeOfString:@"Cell"].location != NSNotFound;
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

static NSMapTable *LxDiagCellStateMap(void) {
	static NSMapTable *map = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		map = [NSMapTable weakToStrongObjectsMapTable];
	});
	return map;
}

static BOOL LxShouldLogDataSourceClass(id tableOrCollection, id ds) {
	static NSMapTable *map = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		map = [NSMapTable weakToStrongObjectsMapTable];
	});
	if (!tableOrCollection) return NO;
	NSString *name = LxClassName(ds);
	@synchronized (map) {
		NSString *last = [map objectForKey:tableOrCollection];
		if (last && [last isEqualToString:name]) return NO;
		[map setObject:(name ?: @"(nil)") forKey:tableOrCollection];
		return YES;
	}
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

static BOOL LxShouldLogMapLine(void) {
	static int count = 0;
	if (count >= 300) return NO;
	count++;
	return YES;
}

static BOOL LxShouldLogChatBindMiss(void) {
	static int count = 0;
	if (count >= 120) return NO;
	count++;
	return YES;
}

static NSMutableSet *LxClassMappedSet(void) {
	static NSMutableSet *set = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		set = [NSMutableSet set];
	});
	return set;
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

static void LxDumpClassMapIfNeeded(id obj) {
	if (!obj) return;
	NSString *className = LxClassName(obj);
	if (className.length == 0) return;
	NSMutableSet *mapped = LxClassMappedSet();
	@synchronized (mapped) {
		if ([mapped containsObject:className]) return;
		[mapped addObject:className];
	}
	Class cls = [obj class];
	if (LxShouldLogMapLine()) {
		LxLogLine(@"[LXMAP] class=%@ begin", className);
	}

	unsigned ivarCount = 0;
	Ivar *ivars = class_copyIvarList(cls, &ivarCount);
	for (unsigned i = 0; i < ivarCount; i++) {
		const char *cname = ivar_getName(ivars[i]);
		if (!cname) continue;
		NSString *name = [NSString stringWithUTF8String:cname];
		if (!LxInterestingName(name)) continue;
		if (!LxShouldLogMapLine()) break;
		LxLogLine(@"[LXMAP] class=%@ ivar=%@", className, name);
	}
	if (ivars) free(ivars);

	unsigned methodCount = 0;
	Method *methods = class_copyMethodList(cls, &methodCount);
	for (unsigned i = 0; i < methodCount; i++) {
		SEL sel = method_getName(methods[i]);
		NSString *name = NSStringFromSelector(sel) ?: @"";
		if (name.length == 0 || [name hasPrefix:@"set"] || [name hasSuffix:@":"]) continue;
		if (!LxInterestingName(name)) continue;
		if (method_getNumberOfArguments(methods[i]) != 2) continue;
		char retType[16] = {0};
		method_getReturnType(methods[i], retType, sizeof(retType));
		if (retType[0] != '@') continue;
		if (!LxShouldLogMapLine()) break;
		LxLogLine(@"[LXMAP] class=%@ sel=%@", className, name);
	}
	if (methods) free(methods);
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
	LxDumpClassMapIfNeeded(cell);

	NSString *path = nil;
	id target = nil;
	LxChatRecalledState state = LxScanChatMsgCellForRecalled(cell, &path, &target);
	if (outTarget) *outTarget = target;
	if (outPath) *outPath = path ?: @"(none)";
	if (state == LxChatRecalledStateRecalled && LxShouldLogMapLine()) {
		LxLogLine(@"[LXPATCH] chat-cell-bind-hit cell=%p path=%@ targetClass=%@",
		          cell, path ?: @"(none)", LxClassName(target));
	}
	return state;
}

static void LxDiagnoseCell(id cell, NSString *reason) {
	if (![cell isKindOfClass:[UIView class]]) return;
	if (!LxIsLikelyAppCellClass(cell)) return;

	if (LxIsChatMsgCellObject(cell) && LxIsSingleChatViewContext((UIView *)cell)) {
		id target = nil;
		NSString *path = nil;
		LxChatRecalledState recalledState = LxChatMsgCellRecalledState(cell, &target, &path);
		NSMapTable *map = LxDiagCellStateMap();
		BOOL shouldLog = NO;
		@synchronized (map) {
			NSNumber *last = [map objectForKey:cell];
			int state = (int)recalledState;
			if (!last || last.intValue != state) {
				[map setObject:@(state) forKey:cell];
				shouldLog = YES;
			}
		}
		if (shouldLog && LxShouldLogDiagLine()) {
			UIView *view = (UIView *)cell;
			LxLogLine(@"[LXDIAG] cell=%@ reason=%@ recalled=%d sel=%@ targetClass=%@ vc=%@ chain=%@",
			          LxClassName(cell),
			          reason ?: @"(nil)",
			          (int)recalledState,
			          path ?: @"(none)",
			          LxClassName(target),
			          LxResponderViewControllerName(view),
			          LxSuperviewChain(view, 6));
		}
		return;
	}

	NSString *sel1 = nil;
	id c1 = LxDiagnosticCandidateFromObject(cell, &sel1);
	NSString *sel2 = nil;
	id c2 = LxDiagnosticCandidateFromObject(c1, &sel2);
	id target = c2 ?: c1;
	NSString *selPath = nil;
	if (c2 && sel1 && sel2) {
		selPath = [NSString stringWithFormat:@"%@.%@", sel1, sel2];
	} else if (sel1) {
		selPath = sel1;
	} else {
		selPath = @"(none)";
	}

	int state = -1;
	if (target) {
		state = LxIsRecalledMessageObjectDeep(target) ? 1 : 0;
	}

	NSMapTable *map = LxDiagCellStateMap();
	BOOL shouldLog = NO;
	@synchronized (map) {
		NSNumber *last = [map objectForKey:cell];
		if (!last || last.intValue != state) {
			[map setObject:@(state) forKey:cell];
			shouldLog = YES;
		}
	}
	if (!shouldLog || !LxShouldLogDiagLine()) return;

	UIView *view = (UIView *)cell;
	LxLogLine(@"[LXDIAG] cell=%@ reason=%@ recalled=%d sel=%@ targetClass=%@ vc=%@ chain=%@",
	          LxClassName(cell),
	          reason ?: @"(nil)",
	          state,
	          selPath,
	          LxClassName(target),
	          LxResponderViewControllerName(view),
	          LxSuperviewChain(view, 6));
}

static BOOL LxCellRecalledState(id cell, id *outTarget, NSString **outSelPath) {
	if (outTarget) *outTarget = nil;
	if (outSelPath) *outSelPath = @"(none)";
	if (!cell) return NO;

	if (LxIsRecalledMessageObjectDeep(cell)) {
		if (outTarget) *outTarget = cell;
		if (outSelPath) *outSelPath = @"self";
		return YES;
	}

	NSString *sel1 = nil;
	id c1 = LxDiagnosticCandidateFromObject(cell, &sel1);
	if (c1 && LxIsRecalledMessageObjectDeep(c1)) {
		if (outTarget) *outTarget = c1;
		if (outSelPath) *outSelPath = sel1 ?: @"(none)";
		return YES;
	}

	NSString *sel2 = nil;
	id c2 = LxDiagnosticCandidateFromObject(c1, &sel2);
	if (c2 && LxIsRecalledMessageObjectDeep(c2)) {
		if (outTarget) *outTarget = c2;
		if (outSelPath) {
			*outSelPath = (sel1 && sel2) ? [NSString stringWithFormat:@"%@.%@", sel1, sel2] : (sel1 ?: @"(none)");
		}
		return YES;
	}

	NSString *sel3 = nil;
	id c3 = LxDiagnosticCandidateFromObject(c2, &sel3);
	if (c3 && LxIsRecalledMessageObjectDeep(c3)) {
		if (outTarget) *outTarget = c3;
		if (outSelPath) {
			if (sel1 && sel2 && sel3) {
				*outSelPath = [NSString stringWithFormat:@"%@.%@.%@", sel1, sel2, sel3];
			} else if (sel1 && sel2) {
				*outSelPath = [NSString stringWithFormat:@"%@.%@", sel1, sel2];
			} else {
				*outSelPath = sel1 ?: @"(none)";
			}
		}
		return YES;
	}

	NSString *sel4 = nil;
	id c4 = LxDiagnosticCandidateFromObject(c3, &sel4);
	if (c4 && LxIsRecalledMessageObjectDeep(c4)) {
		if (outTarget) *outTarget = c4;
		if (outSelPath) {
			if (sel1 && sel2 && sel3 && sel4) {
				*outSelPath = [NSString stringWithFormat:@"%@.%@.%@.%@", sel1, sel2, sel3, sel4];
			} else {
				*outSelPath = sel1 ?: @"(none)";
			}
		}
		return YES;
	}

	return NO;
}

static BOOL LxShouldLogGenericBadge(void) {
	static int count = 0;
	if (count >= 160) return NO;
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
		if (score > bestScore) {
			bestScore = score;
			best = v;
		}
	}

	if (!best) return contentView.bounds;
	return [contentView convertRect:best.bounds fromView:best];
}

__attribute__((unused)) static void LxUpdateGenericCellBadge(id cell, NSString *reason) {
	if (![cell isKindOfClass:[UIView class]]) return;
	if (LxIsChatMsgCellObject(cell)) return;
	if (!LxIsLikelyAppCellClass(cell)) return;

	UIView *contentView = (UIView *)LxObjcMsgSendId(cell, @selector(contentView));
	if (![contentView isKindOfClass:[UIView class]]) return;

	id target = nil;
	NSString *selPath = nil;
	BOOL recalled = LxCellRecalledState(cell, &target, &selPath);

	UILabel *badge = (UILabel *)[contentView viewWithTag:kLxGenericRecalledBadgeTag];
	if (!recalled) {
		if (badge) {
			[badge removeFromSuperview];
			if (LxShouldLogGenericBadge()) {
				LxLogLine(@"[LXPATCH] generic badge remove cell=%@ reason=%@",
				          LxClassName(cell), reason ?: @"(nil)");
			}
		}
		return;
	}

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
	CGFloat badgeH = MAX(18.0, CGRectGetHeight(badge.bounds) + 4.0);
	badge.frame = CGRectMake(8.0, 4.0, badgeW, badgeH);
	if (LxShouldLogGenericBadge()) {
		LxLogLine(@"[LXPATCH] generic badge show cell=%@ reason=%@ sel=%@ target=%@ frame={%.1f,%.1f,%.1f,%.1f}",
		          LxClassName(cell),
		          reason ?: @"(nil)",
		          selPath ?: @"(none)",
		          LxClassName(target),
		          badge.frame.origin.x, badge.frame.origin.y, badge.frame.size.width, badge.frame.size.height);
	}
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
	objc_setAssociatedObject(cell, kLxChatBadgeVisibleKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
	CGFloat contentW = CGRectGetWidth(contentView.bounds);
	CGFloat contentMidX = CGRectGetMidX(contentView.bounds);
	CGFloat anchorMidX = CGRectGetMidX(anchor);
	if (!fromSelfKnown && fabs(anchorMidX - contentMidX) >= 1.0) {
		fromSelf = (anchorMidX > contentMidX);
		fromSelfKnown = YES;
		anchor = LxChatBubbleAnchorRect(cell, contentView, fromSelfKnown, fromSelf);
	}

	BOOL placeOutside = (CGRectGetMinY(anchor) - badgeH - 2.0 >= 1.0);
	CGFloat x = fromSelf ? (CGRectGetMinX(anchor) + 4.0) : (CGRectGetMaxX(anchor) - badgeW - 4.0);
	if (placeOutside) {
		// Place at bubble outer-top corner to avoid covering message text.
		x = fromSelf ? (CGRectGetMinX(anchor) - badgeW * 0.15) : (CGRectGetMaxX(anchor) - badgeW * 0.85);
	}
	x = MAX(2.0, MIN(contentW - badgeW - 2.0, x));
	CGFloat y = placeOutside ? (CGRectGetMinY(anchor) - badgeH - 2.0) : (CGRectGetMinY(anchor) + 2.0);
	y = MAX(1.0, y);
	badge.frame = CGRectMake(x, y, badgeW, badgeH);
	if (wasHidden && LxShouldLogGenericBadge()) {
		LxLogLine(@"[LXPATCH] chat badge show cell=%@ ptr=%p reason=%@ side=%@ known=%d place=%@ path=%@ target=%@ frame={%.1f,%.1f,%.1f,%.1f}",
		          LxClassName(cell),
		          cell,
		          reason ?: @"(nil)",
		          fromSelf ? @"self" : @"other",
		          fromSelfKnown ? 1 : 0,
		          placeOutside ? @"outside" : @"inside",
		          path ?: @"(none)",
		          LxClassName(target),
		          badge.frame.origin.x, badge.frame.origin.y, badge.frame.size.width, badge.frame.size.height);
	}
}

static NSString *LxPrefixedRecalledText(NSString *text) {
	if (![text isKindOfClass:[NSString class]]) return text;
	if ([text hasPrefix:@"[已撤回]"]) return text;
	return [NSString stringWithFormat:@"[已撤回] %@", text];
}

static NSString *LxPlainRecalledTextCandidate(NSString *text) {
	if (![text isKindOfClass:[NSString class]]) return nil;
	if (text.length == 0) return nil;
	if ([text isEqualToString:@"[已撤回]"]) return nil;
	NSString *prefix = @"[已撤回] ";
	if ([text hasPrefix:prefix]) {
		NSString *plain = [text substringFromIndex:prefix.length];
		return plain.length > 0 ? plain : nil;
	}
	return text;
}

static NSMutableSet *LxRecalledPlainTextSet(void) {
	static NSMutableSet *set = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		set = [NSMutableSet set];
	});
	return set;
}

__attribute__((unused)) static void LxTrackRecalledPlainText(NSString *text, NSString *source) {
	NSString *plain = LxPlainRecalledTextCandidate(text);
	if (plain.length == 0 || plain.length > 4096) return;
	NSMutableSet *set = LxRecalledPlainTextSet();
	BOOL shouldLog = NO;
	@synchronized (set) {
		if (![set containsObject:plain]) {
			[set addObject:plain];
			shouldLog = YES;
		}
	}
	if (shouldLog) {
		LxLogLine(@"[LXPATCH] track recalled text source=%@ len=%lu",
		          source ?: @"(nil)", (unsigned long)plain.length);
	}
}

static BOOL LxIsTrackedRecalledPlainText(NSString *text) {
	NSString *plain = LxPlainRecalledTextCandidate(text);
	if (plain.length == 0) return NO;
	NSMutableSet *set = LxRecalledPlainTextSet();
	@synchronized (set) {
		return [set containsObject:plain];
	}
}

__attribute__((unused)) static NSString *LxPatchDisplayTextIfNeeded(NSString *text) {
	if (![text isKindOfClass:[NSString class]]) return text;
	if ([text hasPrefix:@"[已撤回]"]) return text;
	if (!LxIsTrackedRecalledPlainText(text)) return text;
	return LxPrefixedRecalledText(text);
}

__attribute__((unused)) static NSAttributedString *LxPatchDisplayAttributedTextIfNeeded(NSAttributedString *attributedText) {
	if (![attributedText isKindOfClass:[NSAttributedString class]]) return attributedText;
	NSString *plain = attributedText.string ?: @"";
	if (plain.length == 0 || [plain hasPrefix:@"[已撤回]"]) return attributedText;
	if (!LxIsTrackedRecalledPlainText(plain)) return attributedText;

	NSDictionary *attrs = nil;
	if (attributedText.length > 0) {
		attrs = [attributedText attributesAtIndex:0 effectiveRange:NULL];
	}
	NSAttributedString *prefix = [[NSAttributedString alloc] initWithString:@"[已撤回] " attributes:attrs];
	NSMutableAttributedString *merged = [[NSMutableAttributedString alloc] initWithAttributedString:prefix];
	[merged appendAttributedString:attributedText];
	return merged;
}

__attribute__((unused)) static BOOL LxShouldLogLabelPatch(void) {
	static int count = 0;
	if (count >= 120) return NO;
	count++;
	return YES;
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

static BOOL LxPatchTextLikeObject(id textObj) {
	if (!textObj) return NO;
	id text = LxObjcMsgSendId(textObj, @selector(text));
	if ([text isKindOfClass:[NSString class]]) {
		NSString *patched = LxPrefixedRecalledText((NSString *)text);
		if (patched != text) {
			LxObjcMsgSendVoidId(textObj, @selector(setText:), patched);
			return YES;
		}
	}

	id attributedText = LxObjcMsgSendId(textObj, @selector(attributedText));
	if (![attributedText isKindOfClass:[NSAttributedString class]]) return NO;
	NSAttributedString *attr = (NSAttributedString *)attributedText;
	NSString *plain = attr.string ?: @"";
	if ([plain hasPrefix:@"[已撤回]"]) return NO;
	NSDictionary *attrs = nil;
	if (attr.length > 0) {
		attrs = [attr attributesAtIndex:0 effectiveRange:NULL];
	}
	NSAttributedString *prefix = [[NSAttributedString alloc] initWithString:@"[已撤回] " attributes:attrs];
	NSMutableAttributedString *merged = [[NSMutableAttributedString alloc] initWithAttributedString:prefix];
	[merged appendAttributedString:attr];
	LxObjcMsgSendVoidId(textObj, @selector(setAttributedText:), merged);
	return YES;
}

static NSString *LxTextTypeForObject(id textObj) {
	if (!textObj) return nil;
	id text = LxObjcMsgSendId(textObj, @selector(text));
	if ([text isKindOfClass:[NSString class]]) return @"text";
	id attr = LxObjcMsgSendId(textObj, @selector(attributedText));
	if ([attr isKindOfClass:[NSAttributedString class]]) return @"attributedText";
	return nil;
}

__attribute__((unused)) static BOOL LxPatchBuilderTextLabel(id builder, NSString **outClass, NSString **outType) {
	if (outClass) *outClass = nil;
	if (outType) *outType = nil;
	if (!builder || ![builder respondsToSelector:@selector(textLabel)]) return NO;
	id label = LxObjcMsgSendId(builder, @selector(textLabel));
	if (outClass) *outClass = LxClassName(label);
	if (outType) *outType = LxTextTypeForObject(label);
	return LxPatchTextLikeObject(label);
}

__attribute__((unused)) static BOOL LxPatchFirstTextLabelInView(UIView *view, NSString **outClass, NSString **outType) {
	if (outClass) *outClass = nil;
	if (outType) *outType = nil;
	if (![view isKindOfClass:[UIView class]]) return NO;
	if (LxPatchTextLikeObject(view)) {
		if (outClass) *outClass = LxClassName(view);
		if (outType) *outType = LxTextTypeForObject(view);
		return YES;
	}
	for (UIView *sub in view.subviews) {
		if (LxPatchFirstTextLabelInView(sub, outClass, outType)) return YES;
	}
	return NO;
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

%hook IMTextMessage

- (id)text {
	id text = %orig;
	return text;
}

- (id)contentText {
	id text = %orig;
	return text;
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
	%orig(text);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
	%orig(attributedText);
}

%end

%hook YYLabel

- (void)setText:(NSString *)text {
	%orig(text);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
	%orig(attributedText);
}

%end

%hook UITableView

- (void)setDataSource:(id)dataSource {
	%orig(dataSource);
	if (LxShouldLogDataSourceClass(self, dataSource) && LxShouldLogDiagLine()) {
		LxLogLine(@"[LXDIAG] UITableView setDataSource ds=%@ table=%p vc=%@",
		          LxClassName(dataSource), self, LxResponderViewControllerName(self));
	}
}

%end

%hook UICollectionView

- (void)setDataSource:(id)dataSource {
	%orig(dataSource);
	if (LxShouldLogDataSourceClass(self, dataSource) && LxShouldLogDiagLine()) {
		LxLogLine(@"[LXDIAG] UICollectionView setDataSource ds=%@ collection=%p vc=%@",
		          LxClassName(dataSource), self, LxResponderViewControllerName(self));
	}
}

%end

%hook LxChatMsgCell

- (void)setChatData:(id)chatData {
	%orig(chatData);
}

- (void)setMsg:(id)msg {
	%orig(msg);
}

- (void)setTemplateContent:(id)templateContent {
	%orig(templateContent);
}

- (void)setChatDataWhenTouchBegin:(id)chatDataWhenTouchBegin {
	%orig(chatDataWhenTouchBegin);
}

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
}

%end

%hook UITableViewCell

- (void)didMoveToWindow {
	%orig;
	if (LxIsChatMsgCellObject(self)) return;
	if (!LxIsSingleChatViewContext(self)) return;
	LxDiagnoseCell(self, @"UITableViewCell.didMoveToWindow");
}

- (void)layoutSubviews {
	%orig;
	if (LxIsChatMsgCellObject(self)) return;
	if (!LxIsSingleChatViewContext(self)) return;
	LxDiagnoseCell(self, @"UITableViewCell.layoutSubviews");
}

%end

%hook UICollectionViewCell

- (void)didMoveToWindow {
	%orig;
	if (![self isKindOfClass:[UIView class]] || !LxIsSingleChatViewContext((UIView *)self)) return;
	LxDiagnoseCell(self, @"UICollectionViewCell.didMoveToWindow");
}

- (void)layoutSubviews {
	%orig;
	if (![self isKindOfClass:[UIView class]] || !LxIsSingleChatViewContext((UIView *)self)) return;
	LxDiagnoseCell(self, @"UICollectionViewCell.layoutSubviews");
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

- (void)updateContent:(CGRect)rect model:(id)model parent:(id)parent builder:(id)builder {
	%orig(rect, model, parent, builder);

	BOOL recalled = LxIsRecalledMessageObjectDeep(model);
	if (!recalled) {
		int state = LxObjcMsgSendInt(model, @selector(msgState), -1);
		recalled = (state == 6 || state == 7);
	}
	if (!recalled) return;
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
