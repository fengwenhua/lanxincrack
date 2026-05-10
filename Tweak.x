#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <string.h>
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

static NSString *const kLXRecalledMessageKeysDefaultsKey = @"lanxincrack.recalledMessageKeys.v1";
static NSString *const kLXLearnedEmoteTypeDoubtDefaultsKey = @"lanxincrack.emoteType.doubt.v1";
// 撤回标识最终复用蓝信自己的 React/EmoteReply 渲染链路，而不是额外自绘 UI。
// 运行时日志已经确认“疑问”对应 TYPE_DOUBT=6；这里保留学习逻辑，是为了蓝信未来
// 改动 enum 数值时，仍能从真实 React 数据里重新学到正确值。
static const int kLXEmoteTypeDoubtDefault = 6;
static char kLXRecalledAssociatedKey;
static char kLXSyntheticEmoteListAssociatedKey;

// 这几类全局状态分别服务于不同生命周期：
// 1. gLXRecalledMessageKeys：记录哪些消息曾经被撤回，即使 msgState 被改回正常值也能识别。
// 2. gLXSyntheticEmoteListsByMessageKey：缓存合成后的 React 列表，避免 cell 反复布局时重复追加。
// 3. gLXEmoteReplySampleList / Item：保存真实 React 消息样本，空列表消息需要借它构造同类型对象。
// 4. gLXLoggedSyntheticFailures：失败日志去重，避免某条消息无法合成时持续刷日志。
static __strong NSMutableSet<NSString *> *gLXRecalledMessageKeys = nil;
static __strong NSMutableDictionary<NSString *, id> *gLXSyntheticEmoteListsByMessageKey = nil;
static int gLXSyntheticEmoteCacheMarkerType = 0;
static __strong id gLXEmoteReplySampleList = nil;
static __strong id gLXEmoteReplySampleItem = nil;
static __strong NSMutableSet<NSString *> *gLXLoggedSyntheticFailures = nil;

static void LxEnsureEmoteRuntimeSets(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLXLoggedSyntheticFailures = [NSMutableSet set];
        gLXSyntheticEmoteListsByMessageKey = [NSMutableDictionary dictionary];
    });
}

static void LxClearAllSyntheticEmoteLists(void) {
    LxEnsureEmoteRuntimeSets();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        [gLXSyntheticEmoteListsByMessageKey removeAllObjects];
    }
}

// 蓝信内部消息对象和 Protobuf 扩展对象没有可用头文件，直接 objc_msgSend 容易因为
// 返回类型不匹配导致崩溃。下面这些工具函数会先检查 selector、method signature 和
// 返回类型，再在 @try/@catch 中调用，尽量把私有 API 变化降级为“拿不到值”。
static NSString *LxTrimmedDescription(id value) {
    if (!value) return nil;
    NSString *desc = nil;
    @try {
        desc = [value description];
    } @catch (__unused NSException *exception) {
        desc = nil;
    }
    if (desc.length == 0) return nil;
    if (desc.length > 240) {
        desc = [[desc substringToIndex:240] stringByAppendingString:@"..."];
    }
    return desc;
}

static const char *LxSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static id LxObjectResult(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature) return nil;
    const char *returnType = LxSkipTypeQualifiers(signature.methodReturnType);
    if (returnType[0] != '@' && returnType[0] != '#') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL LxIntegerResult(id object, NSString *selectorName, long long *outValue) {
    if (!object || selectorName.length == 0 || !outValue) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature) return NO;
    const char *returnType = LxSkipTypeQualifiers(signature.methodReturnType);
    if (!strchr("cCsSiIlLqQB", returnType[0])) return NO;
    @try {
        *outValue = ((long long (*)(id, SEL))objc_msgSend)(object, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL LxSetIntegerValue(id object, NSString *selectorName, int value) {
    if (!object || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, int))objc_msgSend)(object, selector, value);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL LxSetObjectValue(id object, NSString *selectorName, id value) {
    if (!object || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id LxCopyLikeObject(id object) {
    if (!object) return nil;
    @try {
        if ([object respondsToSelector:@selector(mutableCopy)]) {
            return [object mutableCopy];
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        if ([object respondsToSelector:@selector(copy)]) {
            return [object copy];
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static int LxCurrentMarkerEmoteType(void) {
    NSInteger learned = [[NSUserDefaults standardUserDefaults] integerForKey:kLXLearnedEmoteTypeDoubtDefaultsKey];
    if (learned > 0 && learned <= INT_MAX) return (int)learned;
    return kLXEmoteTypeDoubtDefault;
}

// emoteReplyInfoList 的 getter 会在列表布局、cell 复用和刷新时被多次调用。
// 如果每次 getter 都重新合成一份 React 列表，可能出现重复追加、重复分配对象和日志噪声。
// 因此按消息 key 缓存 synthetic list；但如果运行时学到了新的 TYPE_DOUBT 数值，
// 旧缓存可能仍带着错误图标，必须整体清空。
static void LxClearSyntheticEmoteCacheIfMarkerChanged(void) {
    int markerType = LxCurrentMarkerEmoteType();
    LxEnsureEmoteRuntimeSets();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        if (gLXSyntheticEmoteCacheMarkerType != 0 && gLXSyntheticEmoteCacheMarkerType != markerType) {
            [gLXSyntheticEmoteListsByMessageKey removeAllObjects];
        }
        gLXSyntheticEmoteCacheMarkerType = markerType;
    }
}

static void LxLearnDoubtEmoteTypeFromItem(id item) {
    if (!item) return;
    id emoteReplyId = LxObjectResult(item, @"emoteReplyId");
    NSString *itemDesc = [[LxTrimmedDescription(item) ?: @"" uppercaseString] copy];
    NSString *replyIdDesc = [[LxTrimmedDescription(emoteReplyId) ?: @"" uppercaseString] copy];
    if (![itemDesc containsString:@"TYPE_DOUBT"] && ![replyIdDesc containsString:@"TYPE_DOUBT"]) return;

    long long emoteType = LLONG_MIN;
    if (!LxIntegerResult(item, @"emoteType", &emoteType) &&
        !LxIntegerResult(emoteReplyId, @"emoteType", &emoteType)) {
        return;
    }
    if (emoteType <= 0 || emoteType > INT_MAX) return;

    NSInteger previous = [[NSUserDefaults standardUserDefaults] integerForKey:kLXLearnedEmoteTypeDoubtDefaultsKey];
    if (previous == (NSInteger)emoteType) return;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)emoteType forKey:kLXLearnedEmoteTypeDoubtDefaultsKey];
    LxClearAllSyntheticEmoteLists();
    LxLogLine(@"[LXEMOTE] learned TYPE_DOUBT emoteType=%lld", emoteType);
}

static BOOL LxObjectLooksLikeClass(id object, NSString *classNamePart) {
    if (!object || classNamePart.length == 0) return NO;
    NSString *className = NSStringFromClass([object class]) ?: @"";
    return [className containsString:classNamePart];
}

// 尽量从消息本身或 coreIMMessage 上提取稳定标识。指针地址只作为最后兜底，
// 因为同一条消息在刷新后可能变成不同对象，优先使用 messageId/localUUID/uuid。
static NSString *LxMessageStableKey(id message) {
    if (!message) return nil;

    NSArray<NSString *> *directSelectors = @[@"messageId", @"localUUID", @"uuid"];
    for (NSString *selectorName in directSelectors) {
        NSString *desc = LxTrimmedDescription(LxObjectResult(message, selectorName));
        if (desc.length > 0) {
            return [NSString stringWithFormat:@"%@:%@", selectorName, desc];
        }
    }

    id coreMessage = LxObjectResult(message, @"coreIMMessage");
    if (coreMessage) {
        for (NSString *selectorName in directSelectors) {
            NSString *desc = LxTrimmedDescription(LxObjectResult(coreMessage, selectorName));
            if (desc.length > 0) {
                return [NSString stringWithFormat:@"core.%@:%@", selectorName, desc];
            }
        }
    }
    return [NSString stringWithFormat:@"ptr:%p", message];
}

// 原始撤回状态会被下面的 msgState hook 改回正常状态，否则消息内容会被蓝信隐藏。
// 这样做的副作用是：后续渲染阶段已经看不出这条消息曾经被撤回。
// 所以这里用 NSUserDefaults + 内存集合保存撤回消息 key，供 React 标识注入逻辑判断。
static NSMutableSet<NSString *> *LxRecalledMessageKeys(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kLXRecalledMessageKeysDefaultsKey];
        gLXRecalledMessageKeys = [NSMutableSet set];
        if ([saved isKindOfClass:[NSArray class]]) {
            for (id item in saved) {
                if ([item isKindOfClass:[NSString class]] && [item length] > 0) {
                    [gLXRecalledMessageKeys addObject:item];
                }
            }
        }
    });
    return gLXRecalledMessageKeys;
}

static void LxPersistRecalledMessageKeys(void) {
    NSArray *allKeys = nil;
    @synchronized (LxRecalledMessageKeys()) {
        allKeys = [[LxRecalledMessageKeys() allObjects] sortedArrayUsingSelector:@selector(compare:)];
        if (allKeys.count > 2000) {
            allKeys = [allKeys subarrayWithRange:NSMakeRange(allKeys.count - 2000, 2000)];
            gLXRecalledMessageKeys = [NSMutableSet setWithArray:allKeys];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:allKeys ?: @[] forKey:kLXRecalledMessageKeysDefaultsKey];
}

static void LxMarkRecalledMessage(id message, int rawState, NSString *source) {
    if (!message) return;
    objc_setAssociatedObject(message, &kLXRecalledAssociatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *key = LxMessageStableKey(message);
    if (key.length == 0) return;

    BOOL inserted = NO;
    @synchronized (LxRecalledMessageKeys()) {
        if (![LxRecalledMessageKeys() containsObject:key]) {
            [LxRecalledMessageKeys() addObject:key];
            inserted = YES;
        }
    }
    if (inserted) {
        LxPersistRecalledMessageKeys();
        LxLogLine(@"[LXRECALL] mark source=%@ self=%p state=%d key=%@", source ?: @"unknown", message, rawState, key);
    }
}

static id LxCoreMessageIdForMessage(id message) {
    id coreMessage = LxObjectResult(message, @"coreIMMessage");
    id coreMessageId = LxObjectResult(coreMessage, @"messageId");
    if (coreMessageId) return coreMessageId;
    return nil;
}

static BOOL LxIsRecalledMessage(id message) {
    if (!message) return NO;
    NSNumber *associated = objc_getAssociatedObject(message, &kLXRecalledAssociatedKey);
    if (associated.boolValue) return YES;

    NSString *key = LxMessageStableKey(message);
    if (key.length == 0) return NO;
    @synchronized (LxRecalledMessageKeys()) {
        return [LxRecalledMessageKeys() containsObject:key];
    }
}

// 对每条消息缓存增强后的 emoteReplyInfoList。蓝信渲染同一个气泡时可能多次访问
// emoteReplyInfoList，如果不缓存，同一条撤回消息可能被重复合成多个疑问标识。
static id LxCachedSyntheticEmoteListForMessage(id message) {
    NSString *key = LxMessageStableKey(message);
    if (key.length == 0) return nil;
    LxEnsureEmoteRuntimeSets();
    LxClearSyntheticEmoteCacheIfMarkerChanged();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        return gLXSyntheticEmoteListsByMessageKey[key];
    }
}

static void LxCacheSyntheticEmoteListForMessage(id message, id list) {
    NSString *key = LxMessageStableKey(message);
    if (key.length == 0 || !list) return;
    LxEnsureEmoteRuntimeSets();
    LxClearSyntheticEmoteCacheIfMarkerChanged();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        gLXSyntheticEmoteListsByMessageKey[key] = list;
    }
}

static void LxClearSyntheticEmoteListForMessage(id message) {
    NSString *key = LxMessageStableKey(message);
    if (key.length == 0) return;
    LxEnsureEmoteRuntimeSets();
    LxClearSyntheticEmoteCacheIfMarkerChanged();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        [gLXSyntheticEmoteListsByMessageKey removeObjectForKey:key];
    }
}

static id LxEmoteItemsObject(id list) {
    if (!list) return nil;
    if ([list isKindOfClass:[NSArray class]]) return list;
    NSArray<NSString *> *selectors = @[
        @"emoteReplyInfoSArray",
        @"emoteReplyInfoS",
        @"emoteReplyInfos",
        @"emoteReplyInfoArray"
    ];
    for (NSString *selectorName in selectors) {
        id value = LxObjectResult(list, selectorName);
        if (value) return value;
    }
    return nil;
}

static NSUInteger LxCollectionCount(id collection) {
    if (!collection) return 0;
    if ([collection respondsToSelector:@selector(count)]) {
        @try {
            return ((NSUInteger (*)(id, SEL))objc_msgSend)(collection, @selector(count));
        } @catch (__unused NSException *exception) {
        }
    }
    return 0;
}

static id LxCollectionObjectAtIndex(id collection, NSUInteger index) {
    if (!collection || index >= LxCollectionCount(collection)) return nil;
    @try {
        if ([collection respondsToSelector:@selector(objectAtIndex:)]) {
            return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection, @selector(objectAtIndex:), index);
        }
        if ([collection respondsToSelector:@selector(objectAtIndexedSubscript:)]) {
            return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection, @selector(objectAtIndexedSubscript:), index);
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static id LxEmoteItemAtIndex(id list, NSUInteger index);

static id LxFirstEmoteItem(id list) {
    return LxEmoteItemAtIndex(list, 0);
}

static BOOL LxCollectionAddObject(id collection, id object) {
    if (!collection || !object || ![collection respondsToSelector:@selector(addObject:)]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(collection, @selector(addObject:), object);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSUInteger LxEmoteItemCount(id list) {
    if (!list) return 0;
    if ([list isKindOfClass:[NSArray class]]) return [(NSArray *)list count];

    NSArray<NSString *> *countSelectors = @[
        @"emoteReplyInfoSArray_Count",
        @"emoteReplyInfoS_Count",
        @"emoteReplyInfoSCount",
        @"emoteReplyInfosArray_Count",
        @"emoteReplyInfos_Count"
    ];
    for (NSString *selectorName in countSelectors) {
        long long count = 0;
        if (LxIntegerResult(list, selectorName, &count) && count > 0) {
            return (NSUInteger)count;
        }
    }

    id items = LxEmoteItemsObject(list);
    NSUInteger collectionCount = LxCollectionCount(items);
    if (collectionCount > 0) return collectionCount;

    return LxCollectionCount(list);
}

static id LxEmoteItemAtIndex(id list, NSUInteger index) {
    if (!list) return nil;
    if ([list isKindOfClass:[NSArray class]]) return LxCollectionObjectAtIndex(list, index);

    NSArray<NSString *> *indexSelectors = @[
        @"emoteReplyInfoSArrayAtIndex:",
        @"emoteReplyInfoSAtIndex:",
        @"emoteReplyInfosArrayAtIndex:",
        @"emoteReplyInfosAtIndex:"
    ];
    for (NSString *selectorName in indexSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![list respondsToSelector:selector]) continue;
        @try {
            id item = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(list, selector, index);
            if (item) return item;
        } @catch (__unused NSException *exception) {
        }
    }

    id items = LxEmoteItemsObject(list);
    id item = LxCollectionObjectAtIndex(items, index);
    if (item) return item;
    return LxCollectionObjectAtIndex(list, index);
}

static BOOL LxEmoteListAddItem(id list, id item) {
    if (!list || !item) return NO;
    if ([list isKindOfClass:[NSMutableArray class]]) {
        [(NSMutableArray *)list addObject:item];
        return YES;
    }

    NSArray<NSString *> *addSelectors = @[
        @"addEmoteReplyInfoS:",
        @"addEmoteReplyInfoSArray:",
        @"addEmoteReplyInfos:",
        @"addEmoteReplyInfosArray:",
        @"addEmoteReplyInfo:"
    ];
    for (NSString *selectorName in addSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![list respondsToSelector:selector]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(list, selector, item);
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }

    id items = LxEmoteItemsObject(list);
    return LxCollectionAddObject(items ?: list, item);
}

static BOOL LxListHasMarkerEmote(id list) {
    int markerType = LxCurrentMarkerEmoteType();
    NSUInteger count = LxEmoteItemCount(list);
    for (NSUInteger i = 0; i < count; i++) {
        id item = LxEmoteItemAtIndex(list, i);
        long long emoteType = LLONG_MIN;
        if (LxIntegerResult(item, @"emoteType", &emoteType) && emoteType == markerType) {
            return YES;
        }
        id emoteReplyId = LxObjectResult(item, @"emoteReplyId");
        if (LxIntegerResult(emoteReplyId, @"emoteType", &emoteType) && emoteType == markerType) {
            return YES;
        }
        NSString *desc = LxTrimmedDescription(item);
        if ([[desc uppercaseString] containsString:@"DOUBT"]) {
            return YES;
        }
        desc = LxTrimmedDescription(emoteReplyId);
        if ([[desc uppercaseString] containsString:@"DOUBT"]) {
            return YES;
        }
    }
    return NO;
}

// 真实 React 消息会带有完整的 CoreExtendMessage_EmoteReplyInfoList /
// CoreExtendMessage_EmoteReplyInfo / CoreExtendMessage_EmoteReplyId 对象。
// 撤回消息经常只有空列表，无法直接 new 出完整结构，所以这里记住真实样本：
// 后续合成撤回标识时，复制样本对象并只替换 messageId 和 emoteType。
static void LxRememberEmoteReplySample(id list) {
    if (!list) return;
    id firstItem = LxFirstEmoteItem(list);
    if (!firstItem) return;

    id itemCopy = LxCopyLikeObject(firstItem);
    id listCopy = LxCopyLikeObject(list);
    gLXEmoteReplySampleItem = itemCopy ?: firstItem;
    gLXEmoteReplySampleList = listCopy ?: list;
    LxLearnDoubtEmoteTypeFromItem(firstItem);
}

// 构造单个“疑问”React item 的核心逻辑：
// 1. 优先取当前列表里的真实 item；没有则使用之前缓存的真实 React 样本。
// 2. 复制外层 info 和内层 replyId，避免修改蓝信原始对象。
// 3. 把 replyId.messageId 改成当前被撤回消息的 messageId。
// 4. 把 replyId.emoteType 改成疑问 TYPE_DOUBT。
// 这样返回给蓝信原有 React 渲染器后，UI 会像真实长按 React 一样显示标识。
static id LxSyntheticDoubtEmoteItem(id message, id list) {
    id sourceItem = LxFirstEmoteItem(list) ?: gLXEmoteReplySampleItem;
    if (!sourceItem) {
        LxLogLine(@"[LXEMOTE] skip synthetic: no source item key=%@", LxMessageStableKey(message));
        return nil;
    }
    id sourceReplyId = LxObjectResult(sourceItem, @"emoteReplyId");
    if (!LxObjectLooksLikeClass(sourceReplyId, @"CoreExtendMessage_EmoteReplyId")) {
        LxLogLine(@"[LXEMOTE] skip synthetic: no safe nested emoteReplyId key=%@ itemClass=%@ replyIdClass=%@",
                  LxMessageStableKey(message),
                  NSStringFromClass([sourceItem class]),
                  sourceReplyId ? NSStringFromClass([sourceReplyId class]) : @"(nil)");
        return nil;
    }

    id item = LxCopyLikeObject(sourceItem);
    if (!item && sourceItem) {
        @try {
            item = [[[sourceItem class] alloc] init];
        } @catch (__unused NSException *exception) {
            item = nil;
        }
    }
    if (!item) return nil;

    id replyId = LxCopyLikeObject(sourceReplyId);
    if (!replyId) {
        @try {
            replyId = [[[sourceReplyId class] alloc] init];
        } @catch (__unused NSException *exception) {
            replyId = nil;
        }
    }
    if (!LxObjectLooksLikeClass(replyId, @"CoreExtendMessage_EmoteReplyId")) return nil;

    // 关键逆向结论：emoteType 不在外层 CoreExtendMessage_EmoteReplyInfo 上，
    // 而是在内层 CoreExtendMessage_EmoteReplyId 里。之前把 type 写到外层会无效。
    id coreMessageId = LxCoreMessageIdForMessage(message);
    if (!coreMessageId || !LxSetObjectValue(replyId, @"setMessageId:", coreMessageId)) {
        LxLogLine(@"[LXEMOTE] skip synthetic: set nested messageId failed key=%@ replyIdClass=%@ coreMessageIdClass=%@",
                  LxMessageStableKey(message),
                  NSStringFromClass([replyId class]),
                  coreMessageId ? NSStringFromClass([coreMessageId class]) : @"(nil)");
        return nil;
    }

    BOOL didSetType = NO;
    int markerType = LxCurrentMarkerEmoteType();
    didSetType |= LxSetIntegerValue(replyId, @"setEmoteType:", markerType);
    didSetType |= LxSetIntegerValue(replyId, @"setEmoteTypeValue:", markerType);
    didSetType |= LxSetIntegerValue(replyId, @"setType:", markerType);

    if (!didSetType) {
        LxLogLine(@"[LXEMOTE] skip synthetic: nested emoteType setter missing key=%@ replyIdClass=%@ desc=%@",
                  LxMessageStableKey(message),
                  NSStringFromClass([replyId class]),
                  LxTrimmedDescription(replyId));
        return nil;
    }

    if (!LxSetObjectValue(item, @"setEmoteReplyId:", replyId)) {
        LxLogLine(@"[LXEMOTE] skip synthetic: setEmoteReplyId failed key=%@ itemClass=%@",
                  LxMessageStableKey(message),
                  NSStringFromClass([item class]));
        return nil;
    }
    return item;
}

static id LxSyntheticListFromSample(id syntheticItem) {
    if (!syntheticItem || !gLXEmoteReplySampleList) return nil;
    id list = LxCopyLikeObject(gLXEmoteReplySampleList);
    if (!list) return nil;

    NSMutableArray *items = [NSMutableArray arrayWithObject:syntheticItem];
    if (LxSetObjectValue(list, @"setEmoteReplyInfoSArray:", items) ||
        LxSetObjectValue(list, @"setEmoteReplyInfoS:", items) ||
        LxSetObjectValue(list, @"setEmoteReplyInfos:", items) ||
        LxSetObjectValue(list, @"setEmoteReplyInfoArray:", items)) {
        return list;
    }
    if ([list isKindOfClass:[NSMutableArray class]]) {
        [(NSMutableArray *)list removeAllObjects];
        [(NSMutableArray *)list addObject:syntheticItem];
        return list;
    }
    return nil;
}

static id LxAugmentedEmoteReplyInfoList(id message, id originalList) {
    if (!LxIsRecalledMessage(message)) return originalList;
    if (originalList && LxListHasMarkerEmote(originalList)) return originalList;

    id cachedList = LxCachedSyntheticEmoteListForMessage(message);
    if (cachedList) return cachedList;

    // 这里不新增视图、不改气泡布局，而是返回一份“增强后的 emoteReplyInfoList”。
    // 蓝信原本就会读取这个列表并渲染 React 标识；我们只是在撤回消息的数据层补一条
    // synthetic React 记录，从而复用原生渲染、定位、布局和主题适配。
    id syntheticItem = LxSyntheticDoubtEmoteItem(message, originalList);
    if (!syntheticItem) {
        LxEnsureEmoteRuntimeSets();
        NSString *key = LxMessageStableKey(message) ?: @"unknown";
        @synchronized (gLXLoggedSyntheticFailures) {
            if (![gLXLoggedSyntheticFailures containsObject:key]) {
                [gLXLoggedSyntheticFailures addObject:key];
                LxLogLine(@"[LXEMOTE] cannot synthesize recalled marker key=%@ listClass=%@ sampleItemClass=%@",
                          key,
                          originalList ? NSStringFromClass([originalList class]) : @"(nil)",
                          gLXEmoteReplySampleItem ? NSStringFromClass([gLXEmoteReplySampleItem class]) : @"(nil)");
            }
        }
        return originalList;
    }

    if ([originalList isKindOfClass:[NSArray class]]) {
        NSMutableArray *array = [(NSArray *)originalList mutableCopy] ?: [NSMutableArray array];
        [array addObject:syntheticItem];
        objc_setAssociatedObject(array, &kLXSyntheticEmoteListAssociatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LxCacheSyntheticEmoteListForMessage(message, array);
        return array;
    }

    if (originalList) {
        id listCopy = LxCopyLikeObject(originalList);
        if (listCopy) {
            if (LxEmoteListAddItem(listCopy, syntheticItem)) {
                objc_setAssociatedObject(listCopy, &kLXSyntheticEmoteListAssociatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                LxCacheSyntheticEmoteListForMessage(message, listCopy);
                return listCopy;
            }

            NSMutableArray *newItems = [NSMutableArray array];
            NSUInteger count = LxEmoteItemCount(originalList);
            for (NSUInteger i = 0; i < count; i++) {
                id item = LxEmoteItemAtIndex(originalList, i);
                if (item) [newItems addObject:item];
            }
            [newItems addObject:syntheticItem];
            if (LxSetObjectValue(listCopy, @"setEmoteReplyInfoS:", newItems) ||
                LxSetObjectValue(listCopy, @"setEmoteReplyInfos:", newItems) ||
                LxSetObjectValue(listCopy, @"setEmoteReplyInfoArray:", newItems)) {
                objc_setAssociatedObject(listCopy, &kLXSyntheticEmoteListAssociatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                LxCacheSyntheticEmoteListForMessage(message, listCopy);
                return listCopy;
            }
        }
    }
    id sampleList = LxSyntheticListFromSample(syntheticItem);
    if (sampleList) {
        objc_setAssociatedObject(sampleList, &kLXSyntheticEmoteListAssociatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LxCacheSyntheticEmoteListForMessage(message, sampleList);
        return sampleList;
    }
    return originalList;
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
        // 蓝信用 msgState=6/7 表示消息已撤回。直接返回原状态会让 UI 按撤回逻辑隐藏内容。
        // 这里把状态伪装成 5，让气泡仍按普通消息渲染；同时先记录这条消息，后面再加疑问标识。
        LxMarkRecalledMessage(self, state, @"msgState");
        LxLogLine(@"[LXPATCH] msgState remap self=%p from=%d to=5", self, state);
        return 5;
    }
    return state;
}

- (void)setMsgState:(int)state {
    if (state == 6 || state == 7) {
        // 服务端/数据库把消息状态写成撤回时，立即改写成正常状态保存，避免内容被替换成撤回提示。
        // 记录撤回 key 是为了给这条“仍可见的原消息”补一个明显的 React 标识。
        LxMarkRecalledMessage(self, state, @"setMsgState");
        %orig(5);
        LxLogLine(@"[LXPATCH] setMsgState remap self=%p from=%d to=5", self, state);
        return;
    }
    %orig(state);
}

- (id)emoteReplyInfoList {
    id list = %orig;
    if (list && LxEmoteItemCount(list) > 0) {
        LxRememberEmoteReplySample(list);
    }
    // getter 是最接近 UI 渲染的数据入口：普通消息原样返回，撤回消息返回增强后的 React 列表。
    return LxAugmentedEmoteReplyInfoList(self, list);
}

- (void)setEmoteReplyInfoList:(id)list {
    if (objc_getAssociatedObject(list, &kLXSyntheticEmoteListAssociatedKey)) {
        %orig(list);
        return;
    }
    // 收到真实 React 列表时清理旧 synthetic 缓存，避免真实数据更新后仍复用旧的合成列表。
    LxClearSyntheticEmoteListForMessage(self);
    if (list && LxEmoteItemCount(list) > 0) {
        LxRememberEmoteReplySample(list);
    }
    %orig(list);
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
