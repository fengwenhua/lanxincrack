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

// 返回主日志文件路径。优先写入 App 沙盒的 Library/Caches，方便在同一个构建号下
// 追踪本插件的运行日志，并避免不同构建产生的日志互相覆盖。
static NSString *LxPrimaryLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Caches/lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

// 返回兜底日志文件路径。当沙盒 Caches 目录不可写或路径解析失败时，日志会落到临时目录；
// 这样即使主路径失败，也仍能保留启动、Hook 和撤回标识合成的关键诊断信息。
static NSString *LxFallbackLogPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) tmp = @"/tmp";
    return [tmp stringByAppendingPathComponent:
            [NSString stringWithFormat:@"lanxincrack.%@.log", kLXBuildID ?: @"dev"]];
}

// 返回构建号记录文件路径。每次插件加载时写入当前 build id 和日志路径，便于确认设备上
// 实际运行的是哪一个包，避免调试时误看旧版本日志。
static NSString *LxBuildIDPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/lanxincrack.buildid"];
}

// 用最小依赖的 POSIX open/write 追加一行日志。这里不用 NSLog，是为了避免被宿主日志系统
// 过滤，也避免在早期启动阶段依赖更复杂的 Foundation 文件写入行为。
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

// 插件统一日志入口。负责补时间、进程名，并先写主路径、失败后写兜底路径；
// 所有撤回状态、React 标识合成和启动页绕过日志都从这里输出，方便按 build id 排查。
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

// 懒初始化运行期集合。很多 Hook 可能在不同 UI 刷新路径里触发，因此用 dispatch_once
// 保证字典和失败日志集合只创建一次，避免 nil 集合导致缓存或去重逻辑失效。
static void LxEnsureEmoteRuntimeSets(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLXLoggedSyntheticFailures = [NSMutableSet set];
        gLXSyntheticEmoteListsByMessageKey = [NSMutableDictionary dictionary];
    });
}

// 清空所有已经合成的 React 标识列表。通常在学到新的 TYPE_DOUBT 数值后调用，
// 因为旧列表里已经写入了旧 emoteType，继续复用会显示错误图标。
static void LxClearAllSyntheticEmoteLists(void) {
    LxEnsureEmoteRuntimeSets();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        [gLXSyntheticEmoteListsByMessageKey removeAllObjects];
    }
}

// 蓝信内部消息对象和 Protobuf 扩展对象没有可用头文件，直接 objc_msgSend 容易因为
// 返回类型不匹配导致崩溃。下面这些工具函数会先检查 selector、method signature 和
// 返回类型，再在 @try/@catch 中调用，尽量把私有 API 变化降级为“拿不到值”。
// 安全获取对象的 description，并截断过长内容。日志里只需要识别类名、messageId、
// TYPE_DOUBT 等关键信息，过长的 Protobuf 文本会拖慢日志并影响阅读。
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

// 跳过 Objective-C type encoding 里的修饰符，例如 const、in/out、oneway。
// 这样后续判断返回类型时只看真实基础类型，避免因为修饰符误判 selector 是否安全。
static const char *LxSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

// 安全调用无参数、对象返回值的 selector。蓝信私有对象版本变化时，selector 可能不存在
// 或返回类型改变；这里统一检查后再调用，失败时返回 nil，让上层走降级路径。
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

// 安全调用无参数、整数返回值的 selector。用于读取 count、emoteType 等字段；
// 只有返回类型确实是整数/BOOL 时才写入 outValue，避免把对象指针误当数字解析。
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

// 安全调用一个 int 参数的 setter。主要用于向 CoreExtendMessage_EmoteReplyId 写入
// emoteType；如果蓝信改名或移除 setter，本函数返回 NO，上层会放弃合成而不是崩溃。
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

// 安全调用一个对象参数的 setter。用于写入 messageId、emoteReplyId 或数组字段；
// 私有 Protobuf 对象不稳定，因此所有写入都集中在这里做 selector 存在性和异常保护。
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

// 尽可能复制一个蓝信私有对象。优先 mutableCopy，是为了后续能安全修改字段；
// 如果对象只支持 copy，也先复制出来，避免直接改动宿主原始 React 数据。
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

// 读取当前应该使用的“疑问”emoteType。正常情况下默认值 6 已经由日志验证；
// 如果运行时从真实 TYPE_DOUBT 样本学到了新值，则优先使用持久化的新值。
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

// 从真实 React item 中学习 TYPE_DOUBT 的整数值。用户手动点过“疑问”后，description
// 会暴露 TYPE_DOUBT 字样；一旦读到对应 emoteType，就持久化并清空旧 synthetic 缓存。
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

// 用类名片段判断对象是否像目标私有类。这里不直接依赖 Class 符号，是因为蓝信类可能
// 不在当前编译环境声明，运行时只需要确认它是安全的 EmoteReplyId 类对象。
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

// 持久化撤回消息 key 集合。最多保留 2000 条，防止长期使用后 NSUserDefaults 过大；
// 排序后截断只是为了输出稳定，不承担时间顺序语义。
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

// 标记一条消息曾经被撤回。内存 associated object 解决当前对象生命周期内的快速判断；
// 稳定 key + NSUserDefaults 解决列表刷新后对象指针变化的问题。
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

// 从 IMCoreMessage 的 coreIMMessage.messageId 取出蓝信内部消息 ID。
// 合成 React 标识时必须把这个 ID 写入 EmoteReplyId，否则标识不会绑定到当前消息。
static id LxCoreMessageIdForMessage(id message) {
    id coreMessage = LxObjectResult(message, @"coreIMMessage");
    id coreMessageId = LxObjectResult(coreMessage, @"messageId");
    if (coreMessageId) return coreMessageId;
    return nil;
}

// 判断消息是否被撤回过。优先看当前对象上的 associated 标记，再查持久化 key 集合；
// 这样同一条消息在 cell 复用或重新拉取后仍能被识别为需要补标识的消息。
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

// 缓存某条消息合成后的 emoteReplyInfoList。缓存粒度使用稳定消息 key，而不是对象指针，
// 是为了适配蓝信列表刷新后重新创建消息对象的情况。
static void LxCacheSyntheticEmoteListForMessage(id message, id list) {
    NSString *key = LxMessageStableKey(message);
    if (key.length == 0 || !list) return;
    LxEnsureEmoteRuntimeSets();
    LxClearSyntheticEmoteCacheIfMarkerChanged();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        gLXSyntheticEmoteListsByMessageKey[key] = list;
    }
}

// 清理某条消息的 synthetic React 列表缓存。收到真实 emoteReplyInfoList 更新时调用，
// 避免真实 React 数据变化后仍显示旧的合成列表。
static void LxClearSyntheticEmoteListForMessage(id message) {
    NSString *key = LxMessageStableKey(message);
    if (key.length == 0) return;
    LxEnsureEmoteRuntimeSets();
    LxClearSyntheticEmoteCacheIfMarkerChanged();
    @synchronized (gLXSyntheticEmoteListsByMessageKey) {
        [gLXSyntheticEmoteListsByMessageKey removeObjectForKey:key];
    }
}

// 从蓝信的 emoteReplyInfoList 里取出实际 item 集合。不同版本可能使用不同字段名，
// 所以按多个 selector 尝试；如果传入本身就是 NSArray，则直接当成集合使用。
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

// 安全读取集合数量。React 列表可能是 NSArray，也可能是私有容器；
// 只要它响应 count，就用 objc_msgSend 读取，异常时统一返回 0。
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

// 安全按下标读取集合元素。兼容 objectAtIndex: 和下标访问 selector，
// 读取失败时返回 nil，避免私有容器越界或 selector 异常影响主线程渲染。
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

// 前向声明：下面多个 helper 互相依赖，先声明按下标取 React item 的函数。
static id LxEmoteItemAtIndex(id list, NSUInteger index);

// 读取 React 列表中的第一个 item。样本学习和复制都只需要一个真实 item 作为模板。
static id LxFirstEmoteItem(id list) {
    return LxEmoteItemAtIndex(list, 0);
}

// 向可变集合追加对象。用于 synthetic item 合成后的兜底追加路径；
// 如果集合不可变或不支持 addObject:，返回 NO 让上层尝试其它 setter。
static BOOL LxCollectionAddObject(id collection, id object) {
    if (!collection || !object || ![collection respondsToSelector:@selector(addObject:)]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(collection, @selector(addObject:), object);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// 读取 emoteReplyInfoList 中 React item 的数量。蓝信私有对象可能暴露 count selector，
// 也可能只暴露内部数组；这里按多个已观测字段尝试，尽量兼容不同版本。
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

// 按下标读取 emoteReplyInfoList 中的 React item。优先调用私有的 AtIndex selector，
// 再退回到内部数组或列表本身，保证样本学习和重复标识检测能覆盖更多数据形态。
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

// 向 emoteReplyInfoList 追加一个 synthetic React item。不同蓝信版本可能使用不同 add
// selector 或数组字段，所以这里先尝试专用 add 方法，再退回到内部集合 addObject:。
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

// 判断列表里是否已经有我们的疑问标识。既检查整数 emoteType，也检查 description
// 中的 DOUBT 字样，目的是避免重复追加 synthetic item 或和用户真实点的疑问重复显示。
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

// 当原消息只有空列表、无法直接在原列表上追加 item 时，用之前缓存的真实列表样本
// 复制出一份新列表，并把里面的数组字段替换成只包含 synthetic item 的数组。
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

// 给撤回消息返回增强后的 emoteReplyInfoList。普通消息直接返回原列表；撤回消息会尽量
// 复用原列表副本、内部数组或真实样本列表，最终让蓝信原生 React 渲染器显示疑问标识。
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

// Logos 构造器：插件加载后立即记录构建号和日志路径。这个信息用于确认当前设备
// 运行的包版本，尤其是在反复打包安装时排除“旧 deb 仍在运行”的干扰。
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

// ---- 防撤回：只改核心消息状态，并复用蓝信原生 React 标识渲染 ----
// Hook IMCoreMessage 是防撤回的核心入口：这里拦截撤回状态，保留原消息内容，
// 同时把“这条消息曾经撤回过”的事实交给后续 emoteReplyInfoList 注入逻辑。
%hook IMCoreMessage

// 读取消息状态时，把蓝信的撤回状态 6/7 伪装成普通状态 5。
// 这样 UI 继续渲染原消息内容；撤回事实会先记录下来，稍后通过疑问 React 标识展示。
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

// 写入消息状态时，同样拦截撤回状态 6/7 并改写成 5。
// 这能避免数据库或模型层把消息内容替换成“已撤回”提示，同时保留标识注入所需的撤回 key。
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

// 读取 React 表情/回应列表时，记住真实样本，并在撤回消息上补一条 synthetic 疑问标识。
// 这是最贴近气泡渲染的数据入口，能复用蓝信自己的布局、主题和定位逻辑。
- (id)emoteReplyInfoList {
    id list = %orig;
    if (list && LxEmoteItemCount(list) > 0) {
        LxRememberEmoteReplySample(list);
    }
    // getter 是最接近 UI 渲染的数据入口：普通消息原样返回，撤回消息返回增强后的 React 列表。
    return LxAugmentedEmoteReplyInfoList(self, list);
}

// 写入真实 React 列表时，清理该消息旧的 synthetic 缓存并更新样本。
// 如果传入的是我们自己合成过的列表，则直接放行，避免递归清缓存导致标识丢失。
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

// ---- 水印关闭：让组织水印配置在模型层始终表现为关闭 ----
// Hook 组织客户端模型中的水印配置，覆盖 getter 和 setter，避免 UI 根据远端配置重新开启水印。
%hook LxOrgClientModel

// 读取是否展示水印时固定返回 NO。
- (BOOL)show_watermark { return NO; }
// 读取水印类型时返回 nil，避免下游继续根据类型数组创建水印视图。
- (id)show_watermark_types { return nil; }
// 写入水印开关时强制写入 NO，防止远端配置刷新后把水印重新打开。
- (void)setShow_watermark:(BOOL)show { %orig(NO); }
// 写入水印类型时强制写入 nil，清掉可能驱动水印展示的类型配置。
- (void)setShow_watermark_types:(id)types { %orig(nil); }

%end

// Hook 水印服务层。模型层配置之外，实际视图创建和规则判断也可能从服务类触发，
// 所以这里把服务层的展示判断、配置入口和刷新入口全部改成无水印行为。
%hook WatermarkService

// 静态隐藏水印入口固定传入 YES，确保调用方请求展示时也会被改成隐藏。
+ (void)hiddenWatermark:(BOOL)hidden { %orig(YES); }
// 服务层判断是否展示水印时固定返回 NO。
- (BOOL)isShowWatermark { return NO; }
// 水印规则匹配固定返回 NO，避免任何页面命中水印展示规则。
- (BOOL)complyWatermarkRule:(id)viewController { return NO; }
// 配置页面水印时直接空实现，避免向 viewController 添加水印视图。
- (void)configViewControllerWatermark:(id)viewController {}
// 水印日期刷新直接空实现，避免后台刷新逻辑再次触发展示。
- (void)updateWatermarkDateIfNeeded {}

%end

// ---- 启动页跳过：直接执行启动页完成回调 ----
// Hook 启动页管理器，优先调用 gestureBiometricBlock，绕过开屏页等待流程。
%hook LxSplashManager

// 启动页展示入口。存在完成回调时直接执行并返回；没有回调时保留原逻辑作为兜底。
+ (void)startPageViewShowWithOid:(int)oid launchOptions:(id)launchOptions gestureBiometricBlock:(id)gestureBiometricBlock {
    if (gestureBiometricBlock) {
        ((void (^)(void))gestureBiometricBlock)();
        LxLogLine(@"[LXPATCH] splash bypass done oid=%d", oid);
        return;
    }
    %orig;
}

%end

// ---- 越狱检测绕过：把多个混淆检测入口统一改成“未越狱”或空操作 ----
// 这一组混淆类名来自蓝信运行时符号，主要负责不同维度的越狱/Root 环境检查。
%hook sub_1000010100215841
// 越狱检测布尔入口固定返回 NO，表示未检测到风险。
+ (BOOL)sub_1000010100215849 { return NO; }
// 越狱检测副作用入口空实现，避免继续执行文件/进程/环境扫描。
+ (void)sub_1000010100215846 {}
// 越狱检测副作用入口空实现，避免触发后续上报或退出逻辑。
+ (void)sub_1000010100215842 {}
// 越狱检测副作用入口空实现，保持调用链可返回但不做检查。
+ (void)sub_1000010100215847 {}
// 越狱检测副作用入口空实现，覆盖同组混淆检测方法。
+ (void)sub_1000010100215845 {}
%end

// 第二组混淆越狱检测入口，全部固定返回 NO，表示各项检查均未命中。
%hook sub_1000010100215832
// 混淆检测布尔入口固定返回 NO。
+ (BOOL)sub_1000010100215833 { return NO; }
// 混淆检测布尔入口固定返回 NO。
+ (BOOL)sub_1000010100215834 { return NO; }
// 混淆检测布尔入口固定返回 NO。
+ (BOOL)sub_1000010100215837 { return NO; }
%end

// 自动检测入口固定关闭，避免启动或前台切换时触发越狱检查。
%hook sub_2105813100215866
// autoCheck 固定返回 NO，表示无需自动检测。
+ (BOOL)autoCheck { return NO; }
%end

// 带参数的混淆检测入口固定返回 NO，忽略传入的检测上下文。
%hook sub_1000010100215866
// 参数化检测入口固定返回 NO，避免根据 arg1 触发风险判定。
+ (BOOL)sub_1000010100215867:(id)arg1 { return NO; }
%end

// Root 检测调度类：两个调度方法都改成空实现，阻断后续具体检查。
%hook sub_3108813100215323
// 自动检查调度入口空实现。
+ (void)autocheck {}
// Root 检查调度入口空实现。
+ (void)checkRoot {}
%end

// CoreMessUtils 是更直观的越狱检测工具类，多数调用方会直接查询这些布尔方法。
// 全部返回 NO，让上层业务认为当前设备不是越狱环境。
%hook CoreMessUtils
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak1 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak2 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak3 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak4 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak5 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak6 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak7 { return NO; }
// 越狱检测入口固定返回 NO。
+ (BOOL)isJailBreak8 { return NO; }
%end
