//
//  WeChatFold.m  v5
//  微信群聊批量折叠 —— TrollStore / 巨魔注入版
//
//  v5 变更：
//  1. 移除悬浮按钮（不再有任何悬浮窗 UI）。
//  2. 修复「聊天窗口也出现入口」的 bug：改用 class_addMethod 而非
//     method_setImplementation，避免误改父类实现影响全部 VC。
//  3. 入口只出现在设置页（NewSettingViewController / MMSettingViewController 等），
//     并加了类名白名单二次校验。
//  4. 新增三条诊断：扫描服务中心、扫描界面会话列表、枚举会话类。
//  5. 会话列表兜底：拿不到 MMSessionMgr 时，直接从聊天列表 tableView 的
//     dataSource 里取会话数组。
//
//  零依赖：不用 CydiaSubstrate / Logos %hook，纯 Objective-C runtime。
//  仅供个人自用与学习研究。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 可配置区

static NSString * const kWFSessionMgrClass = @"MMSessionMgr";

// 设置页候选类名（只在这里注入入口）
static NSArray<NSString *> *WFSettingCandidates(void) {
    return @[@"NewSettingViewController",
             @"WCSettingViewController",
             @"MMSettingViewController",
             @"WXSettingViewController",
             @"SettingViewController",
             @"MMMoreSettingViewController"];
}

// 会话列表候选方法名
static NSArray<NSString *> *WFSessionListSelectors(void) {
    return @[@"getAllSessions", @"GetAllSession", @"getSessionList",
             @"getAllSessionInfo", @"getSessions", @"GetSessionList",
             @"getSessionDataList", @"getSessionArray", @"getAllChatSession"];
}

// 会话列表候选属性名
static NSArray<NSString *> *WFSessionListKeys(void) {
    return @[@"m_arrSession", @"m_arrSessionInfo", @"m_sessionList", @"arrSession",
             @"m_arrSessionData", @"m_sessionArray", @"m_arrAllSession"];
}

// 「是否折叠」候选属性名（KVC 写入）
static NSArray<NSString *> *WFFoldKeys(void) {
    return @[@"m_bIsFoldSession", @"m_bFolded", @"m_bIsFold",
             @"m_bShowInFoldList", @"m_uiFoldSessionFlag",
             @"m_bFoldSession", @"m_bInFoldSessionList",
             @"m_uiFoldStatus", @"m_bIsFoldedSession"];
}

// 「设置折叠」候选方法名（BOOL 参数）
static NSArray<NSString *> *WFFoldSelectors(void) {
    return @[@"setFoldSession:", @"foldSession:", @"updateSessionFoldStatus:",
             @"setM_bIsFoldSession:", @"setSessionFold:flag:", @"markSessionAsFolded:",
             @"setIsFold:", @"setFolded:"];
}

static NSArray<NSString *> *WFUserNameKeys(void) {
    return @[@"m_nsUserName", @"m_nsUsrName", @"m_nsFromUser", @"userName", @"m_nsChatRoomName"];
}

static NSArray<NSString *> *WFContactKeys(void) {
    return @[@"m_contact", @"m_oContact", @"contact", @"m_nsContact"];
}

static NSArray<NSString *> *WFSaveSelectors(void) {
    return @[@"UpdateSession:", @"updateSession:", @"saveSession:", @"ModifySession:", @"reloadSession"];
}

#pragma mark - 日志

#define WFLOG(fmt, ...) WFLogMessage(([NSString stringWithFormat:(fmt), ##__VA_ARGS__]))

static NSString *WFLogPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return dir ? [dir stringByAppendingPathComponent:@"WeChatFold.log"] : nil;
}

static void WFLogMessage(NSString *msg) {
    if (!msg) return;
    NSLog(@"[WeChatFold] %@", msg);
    @try {
        NSString *path = WFLogPath();
        if (!path) return;
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) { }
}

static NSString *WFReadLog(void) {
    NSString *log = [NSString stringWithContentsOfFile:WFLogPath()
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    if (!log) log = @"";
    if (log.length > 40000) log = [log substringFromIndex:log.length - 40000];
    return log;
}

static void WFClearLog(void) {
    [@"" writeToFile:WFLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    WFLOG(@"==== 日志已清空 ====");
}

#pragma mark - 运行时工具

static id WFValueForKey(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static BOOL WFSetBoolForKey(id obj, NSString *key, BOOL value) {
    if (!obj || !key) return NO;
    @try { [obj setValue:@(value) forKey:key]; return YES; }
    @catch (NSException *e) { return NO; }
}

static id WFCallNoArg(id target, NSString *selName) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    @try { [inv invoke]; }
    @catch (NSException *e) { WFLOG(@"call -%@ failed: %@", selName, e.reason); return nil; }
    const char *rt = sig.methodReturnType;
    if (rt && (rt[0] == '@' || rt[0] == '#')) {
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    }
    return nil;
}

static id WFCallWithObject(id target, NSString *selName, id arg, BOOL *ok) {
    if (ok) *ok = NO;
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    if (sig.numberOfArguments >= 3 && arg) {
        __unsafe_unretained id a = arg;
        [inv setArgument:&a atIndex:2];
    }
    @try { [inv invoke]; }
    @catch (NSException *e) { WFLOG(@"call -%@ failed: %@", selName, e.reason); return nil; }
    if (ok) *ok = YES;
    const char *rt = sig.methodReturnType;
    if (rt && (rt[0] == '@' || rt[0] == '#')) {
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    }
    return nil;
}

static BOOL WFCallWithBool(id target, NSString *selName, BOOL arg) {
    if (!target) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    if (sig.numberOfArguments >= 3) {
        BOOL a = arg;
        [inv setArgument:&a atIndex:2];
    }
    @try { [inv invoke]; return YES; }
    @catch (NSException *e) { WFLOG(@"call -%@ failed: %@", selName, e.reason); return NO; }
}

#pragma mark - UI 辅助

static UIWindow *WFKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    UIWindow *w = nil;
    if ([app respondsToSelector:@selector(keyWindow)]) w = app.keyWindow;
    if (w) return w;
    for (UIWindow *ww in app.windows) { if (ww.isKeyWindow) return ww; }
    return app.windows.firstObject;
}

static UITableView *WFFindTableViewIn(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *sub in root.subviews) {
        UITableView *t = WFFindTableViewIn(sub);
        if (t) return t;
    }
    return nil;
}

#pragma mark - 对象 dump

static void WFDumpObject(id obj, NSString *tag) {
    if (!obj) { WFLOG(@"dump %@ -> nil", tag); return; }
    Class cls = [obj class];
    WFLOG(@"==== dump %@ : %@ ====", tag, NSStringFromClass(cls));

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *te = ivar_getTypeEncoding(ivars[i]) ?: "?";
        WFLOG(@"  ivar %s (%s)", ivar_getName(ivars[i]) ?: "?", te);
        if (te[0] == '@') {
            id v = nil;
            @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { }
            if (v) {
                NSString *desc = @"";
                if ([v isKindOfClass:[NSString class]]) {
                    desc = [NSString stringWithFormat:@" = \"%@\"", [v length] > 60 ? [v substringToIndex:60] : v];
                } else if ([v isKindOfClass:[NSNumber class]]) {
                    desc = [NSString stringWithFormat:@" = %@", v];
                } else if ([v isKindOfClass:[NSArray class]]) {
                    desc = [NSString stringWithFormat:@" = NSArray(%lu)", (unsigned long)[v count]];
                }
                WFLOG(@"        -> %@%@", NSStringFromClass([v class]), desc);
            }
        }
    }
    free(ivars);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        WFLOG(@"  prop %s", property_getName(props[i]));
    }
    free(props);

    unsigned int mCount = 0;
    Method *methods = class_copyMethodList(cls, &mCount);
    int shown = 0;
    for (unsigned int i = 0; i < mCount && shown < 80; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name rangeOfString:@"old"].location != NSNotFound ||
            [name rangeOfString:@"Fold"].location != NSNotFound ||
            [name rangeOfString:@"Session"].location != NSNotFound ||
            [name rangeOfString:@"Chatroom"].location != NSNotFound ||
            [name rangeOfString:@"ChatRoom"].location != NSNotFound ||
            [name rangeOfString:@"All"].location != NSNotFound ||
            [name rangeOfString:@"List"].location != NSNotFound) {
            WFLOG(@"  method %@", name);
            shown++;
        }
    }
    free(methods);
    WFLOG(@"==== dump %@ 结束 ====", tag);
}

static void WFDumpAllMethods(id obj, NSUInteger limit) {
    if (!obj) return;
    unsigned int mc = 0;
    Method *ms = class_copyMethodList([obj class], &mc);
    NSUInteger shown = 0;
    for (unsigned int i = 0; i < mc && shown < limit; i++) {
        WFLOG(@"  method %@", NSStringFromSelector(method_getName(ms[i])));
        shown++;
    }
    free(ms);
    WFLOG(@"  (共 %u 个方法)", mc);
}

#pragma mark - 诊断 1：服务中心

static NSArray<NSString *> *WFServiceCenterCandidates(void) {
    return @[@"MMServiceCenter", @"WCServiceCenter", @"MMServiceCenterMgr", @"ServiceCenter"];
}

static id WFGetServiceCenter(void) {
    for (NSString *centerName in WFServiceCenterCandidates()) {
        Class centerCls = NSClassFromString(centerName);
        if (!centerCls) continue;
        id center = WFCallNoArg(centerCls, @"defaultCenter");
        if (center) return center;
    }
    return nil;
}

static void WFDumpServiceCenter(void) {
    WFLOG(@"==== 开始扫描服务中心 ====");
    id center = WFGetServiceCenter();
    if (!center) { WFLOG(@"服务中心：全部候选均未取到实例"); return; }
    WFLOG(@"服务中心类：%@", NSStringFromClass([center class]));
    WFLOG(@"---- 服务中心方法列表 ----");
    WFDumpAllMethods(center, 60);

    // 服务中心内部往往有一个字典装着所有已注册服务，key 就是真实类名
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([center class], &ic);
    for (unsigned int i = 0; i < ic; i++) {
        const char *te = ivar_getTypeEncoding(ivs[i]) ?: "?";
        if (te[0] != '@') continue;
        id v = nil;
        @try { v = object_getIvar(center, ivs[i]); } @catch (NSException *e) { continue; }
        if (!v) continue;
        WFLOG(@"  ivar %s -> %@", ivar_getName(ivs[i]) ?: "?", NSStringFromClass([v class]));
        if ([v isKindOfClass:[NSDictionary class]]) {
            NSArray *keys = [v allKeys];
            WFLOG(@"  !! 发现服务字典，共 %lu 项 ----", (unsigned long)keys.count);
            for (id k in keys) {
                NSString *ks = [k isKindOfClass:[NSString class]] ? (NSString *)k : NSStringFromClass([k class]);
                WFLOG(@"     服务: %@", ks);
            }
        } else if ([v isKindOfClass:[NSArray class]]) {
            WFLOG(@"     数组 %lu 项，前几项：", (unsigned long)[v count]);
            NSUInteger n = 0;
            for (id item in v) {
                WFLOG(@"       %@", NSStringFromClass([item class]));
                if (++n >= 20) break;
            }
        }
    }
    free(ivs);
    WFLOG(@"==== 服务中心扫描结束 ====");
}

#pragma mark - 诊断 2：枚举会话相关类

static BOOL WFIsSwiftClassName(NSString *name) {
    if ([name hasPrefix:@"_Tt"]) return YES;
    if ([name containsString:@"."]) return YES;
    return NO;
}

static void WFEnumerateSessionClasses(void) {
    WFLOG(@"==== 开始枚举会话相关类 ====");
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { WFLOG(@"无法获取类列表"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned)n);
    n = objc_getClassList(classes, n);

    NSMutableArray<NSString *> *strong = [NSMutableArray array];   // 高度相关
    NSMutableArray<NSString *> *weak   = [NSMutableArray array];   // 可能相关
    for (int i = 0; i < n; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        NSString *clsName = [NSString stringWithUTF8String:cname];
        if (WFIsSwiftClassName(clsName)) continue;
        NSString *low = [clsName lowercaseString];
        BOOL isSession = [low containsString:@"session"];
        BOOL isChat    = [low containsString:@"chat"] || [low containsString:@"conversation"];
        BOOL isFold    = [low containsString:@"fold"];
        if (isFold || (isSession && ([low containsString:@"mgr"] ||
                                     [low containsString:@"list"] ||
                                     [low containsString:@"service"] ||
                                     [low containsString:@"logic"]))) {
            [strong addObject:clsName];
        } else if (isSession || (isChat && ([low containsString:@"mgr"] || [low containsString:@"list"]))) {
            [weak addObject:clsName];
        }
    }
    free(classes);

    [strong sortUsingSelector:@selector(compare:)];
    [weak sortUsingSelector:@selector(compare:)];

    WFLOG(@"---- 高度相关类 %lu 个 ----", (unsigned long)strong.count);
    for (NSString *name in strong) WFLOG(@"[强] %@", name);
    WFLOG(@"---- 可能相关类 %lu 个 ----", (unsigned long)weak.count);
    NSUInteger c = 0;
    for (NSString *name in weak) { WFLOG(@"[弱] %@", name); if (++c >= 120) { WFLOG(@"(截断)"); break; } }

    // 对高度相关的前若干类，完整 dump 方法
    WFLOG(@"---- 高相关类方法详情 ----");
    NSUInteger k = 0;
    for (NSString *name in strong) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        WFLOG(@"[类] %@  (父类 %@)", name, NSStringFromClass(class_getSuperclass(cls)));
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        NSUInteger shown = 0;
        for (unsigned int j = 0; j < mc && shown < 40; j++) {
            WFLOG(@"    %@", NSStringFromSelector(method_getName(ms[j])));
            shown++;
        }
        free(ms);
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int j = 0; j < ic && j < 25; j++) {
            WFLOG(@"    ivar %s (%s)", ivar_getName(ivs[j]) ?: "?", ivar_getTypeEncoding(ivs[j]) ?: "?");
        }
        free(ivs);
        if (++k >= 12) { WFLOG(@"(详情截断)"); break; }
    }
    WFLOG(@"==== 枚举结束 ====");
}

#pragma mark - 诊断 3：从界面 dataSource 找会话数组

static BOOL WFHasChatroomString(id obj) {
    if (!obj) return NO;
    Class cls = [obj class];
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList(cls, &ic);
    BOOL found = NO;
    for (unsigned int i = 0; i < ic && !found; i++) {
        const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
        if (te[0] != '@') continue;
        id v = nil;
        @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { continue; }
        if ([v isKindOfClass:[NSString class]] &&
            ([v hasSuffix:@"@chatroom"] || [v hasSuffix:@"@im.chatroom"])) {
            found = YES;
        }
    }
    free(ivs);
    if (found) return YES;
    for (NSString *key in WFContactKeys()) {
        id contact = WFValueForKey(obj, key);
        if (contact && WFHasChatroomString(contact)) return YES;
    }
    return NO;
}

static NSString *WFSessionUserName(id session) {
    for (NSString *key in WFUserNameKeys()) {
        id v = WFValueForKey(session, key);
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
    }
    return nil;
}

static void WFScanVCForSessions(UIViewController *vc, int depth, NSArray * __strong *best) {
    if (!vc || depth > 6) return;

    UITableView *tv = WFFindTableViewIn(vc.view);
    if (tv) {
        id ds = tv.dataSource;
        if (ds) {
            WFLOG(@"[VC] %@ -> tableView.dataSource = %@",
                  NSStringFromClass([vc class]), NSStringFromClass([ds class]));
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList([ds class], &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
                if (te[0] != '@') continue;
                NSString *tes = [NSString stringWithUTF8String:te];
                if (!([tes containsString:@"NSArray"] || [tes containsString:@"NSMutableArray"])) continue;
                id v = nil;
                @try { v = object_getIvar(ds, ivs[i]); } @catch (NSException *e) { continue; }
                if (![v isKindOfClass:[NSArray class]]) continue;
                NSUInteger c = [v count];
                if (c < 3) continue;
                id first = [v firstObject];
                if (!first || [first isKindOfClass:[NSString class]] ||
                    [first isKindOfClass:[NSNumber class]] || [first isKindOfClass:[NSDictionary class]]) continue;
                WFLOG(@"    候选数组 ivar %s : %lu 项，元素类 %@",
                      ivar_getName(ivs[i]) ?: "?", (unsigned long)c, NSStringFromClass([first class]));
                if (WFHasChatroomString(first) || WFSessionUserName(first)) {
                    if (!*best || c > [*best count]) *best = v;
                }
            }
            free(ivs);
        }
    }

    for (UIViewController *c in vc.childViewControllers) WFScanVCForSessions(c, depth + 1, best);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        WFScanVCForSessions(nav.topViewController, depth + 1, best);
        WFScanVCForSessions(nav.visibleViewController, depth + 1, best);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        WFLOG(@"[TAB] %@ 共 %lu 个子页", NSStringFromClass([vc class]), (unsigned long)tab.viewControllers.count);
        for (UIViewController *c in tab.viewControllers) WFScanVCForSessions(c, depth + 1, best);
    }
    if (vc.presentedViewController && depth < 3) {
        WFScanVCForSessions(vc.presentedViewController, depth + 1, best);
    }
}

static NSArray *WFSessionsFromUI(void) {
    WFLOG(@"==== 开始扫描界面会话列表 ====");
    UIViewController *root = WFKeyWindow().rootViewController;
    if (!root) { WFLOG(@"拿不到根控制器"); return nil; }
    WFLOG(@"根控制器：%@", NSStringFromClass([root class]));
    NSArray *best = nil;
    WFScanVCForSessions(root, 0, &best);
    if (best) {
        WFLOG(@"界面会话列表命中：%lu 条，元素类 %@",
              (unsigned long)best.count, NSStringFromClass([[best firstObject] class]));
    } else {
        WFLOG(@"界面会话列表：未命中");
    }
    WFLOG(@"==== 界面扫描结束 ====");
    return best;
}

#pragma mark - 会话定位

static NSArray<NSString *> *WFSessionMgrCandidates(void) {
    return @[@"MMSessionMgr", @"SessionMgr", @"WCSessionMgr",
             @"MMSessionService", @"MMSessionManager", @"MMSessionMgrService",
             @"WCConversationMgr", @"ConversationMgr",
             @"MMChatSessionMgr", @"MMChatListMgr", @"MMSessionListMgr"];
}

static id WFGetServiceFrom(id center, Class serviceClass) {
    if (!center || !serviceClass) return nil;
    BOOL ok = NO;
    id svc = WFCallWithObject(center, @"getService:", serviceClass, &ok);
    if (!ok) svc = WFCallWithObject(center, @"getService:", NSStringFromClass(serviceClass), &ok);
    return svc;
}

static id WFGetSessionMgr(void) {
    id center = WFGetServiceCenter();
    if (!center) { WFLOG(@"会话管理器：取不到服务中心"); return nil; }
    for (NSString *mgrName in WFSessionMgrCandidates()) {
        Class mgrCls = NSClassFromString(mgrName);
        if (!mgrCls) continue;
        id svc = WFGetServiceFrom(center, mgrCls);
        if (svc) {
            WFLOG(@"会话管理器命中: %@ (实例类 %@)", mgrName, NSStringFromClass([svc class]));
            return svc;
        }
    }
    WFLOG(@"会话管理器：全部候选均未命中（%@ 类%@）",
          kWFSessionMgrClass, NSClassFromString(kWFSessionMgrClass) ? @"存在" : @"不存在");
    return nil;
}

static NSArray *WFAllSessions(id mgr) {
    for (NSString *selName in WFSessionListSelectors()) {
        id r = WFCallNoArg(mgr, selName);
        if ([r isKindOfClass:[NSArray class]]) {
            WFLOG(@"会话列表命中方法 -%@（%lu 条）", selName, (unsigned long)[r count]);
            return r;
        }
    }
    for (NSString *key in WFSessionListKeys()) {
        id r = WFValueForKey(mgr, key);
        if ([r isKindOfClass:[NSArray class]]) {
            WFLOG(@"会话列表命中属性 %@（%lu 条）", key, (unsigned long)[r count]);
            return r;
        }
    }
    WFLOG(@"未定位到会话列表");
    return nil;
}

static BOOL WFIsChatroomSession(id session) {
    if (WFHasChatroomString(session)) return YES;
    NSString *usr = WFSessionUserName(session);
    if ([usr hasSuffix:@"@chatroom"] || [usr hasSuffix:@"@im.chatroom"]) return YES;
    for (NSString *key in WFContactKeys()) {
        id contact = WFValueForKey(session, key);
        if (!contact) continue;
        NSString *cUsr = nil;
        for (NSString *ukey in WFUserNameKeys()) {
            id v = WFValueForKey(contact, ukey);
            if ([v isKindOfClass:[NSString class]] && [v length] > 0) { cUsr = v; break; }
        }
        if ([cUsr hasSuffix:@"@chatroom"]) return YES;
        id cnt = WFValueForKey(contact, @"m_uiChatRoomMemberCount");
        if ([cnt respondsToSelector:@selector(unsignedIntegerValue)] && [cnt unsignedIntegerValue] > 0) return YES;
        id cnt2 = WFValueForKey(contact, @"m_nsMemberCount");
        if ([cnt2 respondsToSelector:@selector(unsignedIntegerValue)] && [cnt2 unsignedIntegerValue] > 0) return YES;
        id flag = WFValueForKey(contact, @"m_bIsChatroom");
        if ([flag respondsToSelector:@selector(boolValue)] && [flag boolValue]) return YES;
    }
    return NO;
}

#pragma mark - 折叠逻辑

static NSInteger gWFTotalSessions = 0;
static NSInteger gWFChatrooms     = 0;
static NSInteger gWFSuccess       = 0;

static BOOL WFApplyFoldToSession(id session, BOOL fold) {
    for (NSString *key in WFFoldKeys()) {
        if (WFSetBoolForKey(session, key, fold)) {
            WFLOG(@"折叠命中属性 %@ = %@", key, fold ? @"YES" : @"NO");
            return YES;
        }
    }
    for (NSString *selName in WFFoldSelectors()) {
        if (WFCallWithBool(session, selName, fold)) {
            WFLOG(@"折叠命中方法 -%@(%@)", selName, fold ? @"YES" : @"NO");
            return YES;
        }
    }
    for (NSString *ckey in WFContactKeys()) {
        id contact = WFValueForKey(session, ckey);
        if (!contact) continue;
        for (NSString *key in WFFoldKeys()) {
            if (WFSetBoolForKey(contact, key, fold)) {
                WFLOG(@"折叠命中联系人属性 %@ = %@", key, fold ? @"YES" : @"NO");
                return YES;
            }
        }
    }
    return NO;
}

static NSInteger WFRunFold(BOOL fold, NSArray *sessions, id mgr) {
    if (!sessions) return -1;

    NSInteger success = 0, total = 0;
    BOOL dumped = NO;
    gWFTotalSessions = (NSInteger)sessions.count;
    gWFChatrooms = 0;
    gWFSuccess = 0;

    for (id session in sessions) {
        if (!WFIsChatroomSession(session)) continue;
        total++;
        if (WFApplyFoldToSession(session, fold)) {
            success++;
            if (mgr) {
                for (NSString *saveSel in WFSaveSelectors()) {
                    if (WFCallWithObject(mgr, saveSel, session, NULL)) break;
                }
            }
        } else if (!dumped) {
            WFDumpObject(session, @"Session[群聊]");
            dumped = YES;
        }
    }

    gWFChatrooms = total;
    gWFSuccess = success;
    WFLOG(@"%@ 结果：成功 %ld / 群聊 %ld / 会话总数 %ld",
          fold ? @"折叠" : @"展开", (long)success, (long)total, (long)sessions.count);
    return success;
}

static void WFReloadVisibleTables(void) {
    UIWindow *w = WFKeyWindow();
    if (!w) return;
    NSUInteger n = 0;
    for (UIView *sub in w.subviews) {
        UITableView *tv = WFFindTableViewIn(sub);
        if (tv) { [tv reloadData]; if (++n >= 4) break; }
    }
    if (n) WFLOG(@"已刷新 %lu 个列表", (unsigned long)n);
}

#pragma mark - Hook 记录

static NSMutableString *gWFHookReport = nil;

static void WFNoteHook(NSString *clsName, BOOL ok, NSString *note) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWFHookReport = [NSMutableString string]; });
    [gWFHookReport appendFormat:@"%@ %@ %@\n", ok ? @"[OK]" : @"[--]", clsName, note ?: @""];
}

#pragma mark - WFManager

@interface WFManager : NSObject
@property (nonatomic, weak) UIViewController *lastVC;
@property (nonatomic, weak) UIViewController *lastSettingVC;
+ (instancetype)shared;
- (void)injectSettingEntry:(UIViewController *)vc;
- (void)showMenuFrom:(UIViewController *)vc;
- (void)showBootAlertOn:(UIViewController *)vc;
- (void)showLogFrom:(UIViewController *)vc;
- (void)copyLogToPasteboard;
- (void)closeLog;
- (void)alert:(NSString *)msg from:(UIViewController *)vc;
@end

@implementation WFManager

+ (instancetype)shared {
    static WFManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[WFManager alloc] init]; });
    return m;
}

static BOOL WFIsSettingVC(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    for (NSString *c in WFSettingCandidates()) {
        if ([name isEqualToString:c]) return YES;
        Class kls = NSClassFromString(c);
        if (kls && [vc isKindOfClass:kls]) return YES;
    }
    return NO;
}

#pragma mark 设置页入口

- (void)injectSettingEntry:(UIViewController *)vc {
    @try {
        if (!WFIsSettingVC(vc)) return;
        UITableView *tv = WFFindTableViewIn(vc.view);
        if (!tv) return;
        if (tv.tableFooterView && tv.tableFooterView.tag == 987654) return;

        CGFloat w = tv.bounds.size.width > 0 ? tv.bounds.size.width : 320;
        UIView *entry = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
        entry.tag = 987654;

        UIColor *bg = [UIColor whiteColor];
        UIColor *fg = [UIColor blackColor];
        if (@available(iOS 13.0, *)) {
            bg = [UIColor systemBackgroundColor];
            fg = [UIColor labelColor];
        }
        entry.backgroundColor = bg;

        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0.5)];
        line.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.3];
        [entry addSubview:line];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, w - 60, 40)];
        lb.text = @"群聊批量折叠";
        lb.font = [UIFont systemFontOfSize:16];
        lb.textColor = fg;
        [entry addSubview:lb];

        UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectMake(w - 28, 16, 14, 24)];
        arrow.text = @">";
        arrow.font = [UIFont systemFontOfSize:15];
        arrow.textColor = [[UIColor grayColor] colorWithAlphaComponent:0.6];
        [entry addSubview:arrow];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = entry.bounds;
        [btn addTarget:self action:@selector(onSettingEntryTap) forControlEvents:UIControlEventTouchUpInside];
        [entry addSubview:btn];

        self.lastSettingVC = vc;
        tv.tableFooterView = entry;
        WFLOG(@"设置页入口已注入：%@", NSStringFromClass([vc class]));
    } @catch (NSException *e) {
        WFLOG(@"设置页入口注入失败：%@", e.reason);
    }
}

- (void)onSettingEntryTap {
    UIViewController *vc = self.lastSettingVC ?: self.lastVC;
    if (!vc) return;
    [self showMenuFrom:vc];
}

#pragma mark 菜单

- (void)showMenuFrom:(UIViewController *)vc {
    if (!vc) return;
    self.lastVC = vc;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"微信群聊批量折叠"
                                                               message:@"选择操作"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *fold = [UIAlertAction actionWithTitle:@"折叠全部群聊"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) { [self run:YES from:vc]; }];
    UIAlertAction *unfold = [UIAlertAction actionWithTitle:@"展开全部群聊"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self run:NO from:vc]; }];
    UIAlertAction *diag1 = [UIAlertAction actionWithTitle:@"诊断1：扫描服务中心"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发：扫描服务中心 ====");
        WFDumpServiceCenter();
        [self alert:@"已扫描服务中心。点「查看日志」→「复制全部」发给我。" from:vc];
    }];
    UIAlertAction *diag2 = [UIAlertAction actionWithTitle:@"诊断2：扫描界面会话列表"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发：扫描界面会话列表 ====");
        NSArray *s = WFSessionsFromUI();
        if (s.count) WFDumpObject([s firstObject], @"Session[0]");
        [self alert:@"已扫描界面会话列表。点「查看日志」→「复制全部」发给我。" from:vc];
    }];
    UIAlertAction *diag3 = [UIAlertAction actionWithTitle:@"诊断3：枚举会话相关类"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发：枚举会话相关类 ====");
        WFEnumerateSessionClasses();
        [self alert:@"已枚举会话相关类。点「查看日志」→「复制全部」发给我。" from:vc];
    }];
    UIAlertAction *viewLog = [UIAlertAction actionWithTitle:@"查看日志"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"清空日志"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *a) { WFClearLog(); [self alert:@"日志已清空。" from:vc]; }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [ac addAction:fold]; [ac addAction:unfold];
    [ac addAction:diag1]; [ac addAction:diag2]; [ac addAction:diag3];
    [ac addAction:viewLog]; [ac addAction:clear]; [ac addAction:cancel];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = vc.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(0, 0, 1, 1);
    }
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark 执行

- (void)run:(BOOL)fold from:(UIViewController *)vc {
    // 取会话列表必须主线程：第二条路径要读界面 dataSource
    id mgr = WFGetSessionMgr();
    NSArray *sessions = mgr ? WFAllSessions(mgr) : nil;
    NSString *source = mgr ? @"MMSessionMgr" : @"";
    if (!sessions) {
        sessions = WFSessionsFromUI();
        source = @"界面 dataSource";
        if (sessions) WFLOG(@"会话列表来自界面（%lu 条）", (unsigned long)sessions.count);
    }

    if (!sessions) {
        WFLOG(@"两条路径都没拿到会话列表");
        WFEnumerateSessionClasses();
        [self alert:@"失败：没拿到会话列表。\n\n已自动写入诊断。点「查看日志」→「复制全部」发给我。" from:vc];
        return;
    }

    NSArray *snapshot = sessions;
    NSString *srcName = source;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger n = WFRunFold(fold, snapshot, mgr);
        NSInteger totalSessions = gWFTotalSessions;
        NSInteger chatrooms = gWFChatrooms;
        dispatch_async(dispatch_get_main_queue(), ^{
            WFReloadVisibleTables();
            NSString *msg;
            if (totalSessions == 0) {
                msg = @"失败：会话列表是空的。";
            } else if (chatrooms == 0) {
                msg = [NSString stringWithFormat:@"拿到 %ld 条会话（来源 %@），但一条群聊都没认出来。\n\n点「查看日志」发给我。", (long)totalSessions, srcName];
            } else if (n == 0) {
                msg = [NSString stringWithFormat:@"认出 %ld 个群聊，但一个都没折叠成功。\n\n折叠属性/方法名没命中，日志里已 dump 真实属性名，点「查看日志」发给我。", (long)chatrooms];
            } else {
                msg = [NSString stringWithFormat:@"成功 %ld 个，共识别 %ld 个群聊（会话总数 %ld，来源 %@）。", (long)n, (long)chatrooms, (long)totalSessions, srcName];
            }
            [self alert:msg from:vc];
        });
    });
}

#pragma mark 启动自检弹窗

- (NSString *)statusReport {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"插件已加载。\n\n"];
    [s appendFormat:@"%@", gWFHookReport ?: @"(hook 未执行)\n"];
    [s appendFormat:@"\nMMServiceCenter 类：%@\n", NSClassFromString(@"MMServiceCenter") ? @"存在" : @"不存在"];
    [s appendFormat:@"MMSessionMgr 类：%@\n", NSClassFromString(kWFSessionMgrClass) ? @"存在" : @"不存在"];
    id mgr = WFGetSessionMgr();
    [s appendFormat:@"会话管理器：%@\n", mgr ? @"已获取" : @"未获取"];
    if (mgr) {
        NSArray *ss = WFAllSessions(mgr);
        [s appendFormat:@"会话数量：%@\n", ss ? [NSString stringWithFormat:@"%lu", (unsigned long)ss.count] : @"取不到列表"];
    }
    [s appendString:@"\n入口位置：微信 → 我 → 设置 → 页面最底部"];
    return s;
}

- (void)showBootAlertOn:(UIViewController *)vc {
    if (!vc) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WFBootAlertDisabled"]) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"WeChatFold v5"
                                                               message:[self statusReport]
                                                        preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"查看日志"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"不再自动提示"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"WFBootAlertDisabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

    [vc presentViewController:ac animated:YES completion:nil];
    WFLOG(@"启动自检弹窗已显示");
}

#pragma mark 日志查看器

- (void)showLogFrom:(UIViewController *)vc {
    NSString *log = WFReadLog();
    if (log.length == 0) log = @"(暂无日志)\n\n先执行一次折叠或诊断，再回来看这里。";

    UIViewController *logVC = [[UIViewController alloc] init];
    logVC.title = @"WeChatFold 日志";
    UIColor *bg = [UIColor whiteColor];
    UIColor *fg = [UIColor blackColor];
    if (@available(iOS 13.0, *)) { bg = [UIColor systemBackgroundColor]; fg = [UIColor labelColor]; }
    logVC.view.backgroundColor = bg;

    UITextView *tv = [[UITextView alloc] initWithFrame:logVC.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.text = log;
    tv.font = [UIFont systemFontOfSize:11];
    tv.editable = NO;
    tv.backgroundColor = bg;
    tv.textColor = fg;
    [logVC.view addSubview:tv];

    logVC.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制全部"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(copyLogToPasteboard)];
    logVC.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(closeLog)];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [vc presentViewController:nav animated:YES completion:nil];
}

- (void)copyLogToPasteboard {
    NSString *log = WFReadLog();
    if (log) {
        [UIPasteboard generalPasteboard].string = log;
        WFLOG(@"日志已复制到剪贴板（%lu 字符）", (unsigned long)log.length);
    }
}

- (void)closeLog {
    [WFKeyWindow().rootViewController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark 通用弹窗

- (void)alert:(NSString *)msg from:(UIViewController *)vc {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"微信群聊折叠"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - Hook 安装

static NSMutableSet<NSString *> *gWFHooked = nil;

static void WFHookSettingVC(Class cls) {
    if (!cls) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWFHooked = [NSMutableSet set]; });

    NSString *clsName = NSStringFromClass(cls);
    if ([gWFHooked containsObject:clsName]) return;

    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WFNoteHook(clsName, NO, @"(无 viewDidAppear:)");
        WFLOG(@"%@ 没有 viewDidAppear:", clsName);
        return;
    }
    [gWFHooked addObject:clsName];

    IMP orig = method_getImplementation(m);           // 可能是继承来的实现
    const char *types = method_getTypeEncoding(m) ?: "v@:B";
    IMP newIMP = imp_implementationWithBlock(^(id _self, BOOL animated) {
        if (orig) ((void (*)(id, SEL, BOOL))orig)(_self, sel, animated);
        @try {
            if ([_self isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)_self;
                [[WFManager shared] setLastVC:vc];
                [[WFManager shared] injectSettingEntry:vc];
            }
        } @catch (NSException *e) {
            WFLOG(@"hook 回调异常：%@", e.reason);
        }
    });

    // 关键：先尝试给 cls 自己加一份实现。
    // 若 cls 本来没有自己的实现，class_addMethod 成功 → 只影响 cls 及其子类，
    // 不会污染父类，也就不会波及聊天页等无关 VC。
    if (!class_addMethod(cls, sel, newIMP, types)) {
        method_setImplementation(m, newIMP);   // cls 已有自己的实现，安全替换
    }
    WFNoteHook(clsName, YES, @"(设置页入口)");
    WFLOG(@"已 hook 设置页 %@", clsName);
}

static void WFInstallHooks(void) {
    BOOL any = NO;
    for (NSString *name in WFSettingCandidates()) {
        Class c = NSClassFromString(name);
        if (c) { WFHookSettingVC(c); any = YES; }
    }
    if (!any) WFLOG(@"设置页候选类名一个都没命中");
}

#pragma mark - 启动自检调度

static void WFTryBootAlert(int attempt) {
    if (attempt > 25) { WFLOG(@"启动弹窗：超时未找到根控制器"); return; }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WFBootAlertDisabled"]) return;

    UIViewController *root = WFKeyWindow().rootViewController;
    if (!root || !root.view.window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WFTryBootAlert(attempt + 1); });
        return;
    }
    [[WFManager shared] setLastVC:root];
    [[WFManager shared] showBootAlertOn:root];
}

#pragma mark - 入口

__attribute__((constructor))
static void WFEntry(void) {
    WFLOG(@"=== WeChatFold dylib 已加载 v5 (pid=%d) ===", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { WFInstallHooks(); }
        @catch (NSException *e) { WFLOG(@"安装 hook 失败：%@", e.reason); }
        WFTryBootAlert(0);
    });
}
