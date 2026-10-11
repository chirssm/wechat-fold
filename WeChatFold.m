//
//  WeChatFold.m  v9
//  微信群聊批量折叠 —— TrollStore / 巨魔注入版
//
//  v9 变更（针对「选择朋友」页定位失败）：
//  1. 【关键修复】v8 的黑名单里有 "Contact"，而「选择朋友」页的类名几乎必然
//     含 Contact，导致页面在匹配前就被自己拦掉了。黑名单收窄为真正不能碰的
//     几类页面（聊天窗口/主界面/设置/朋友圈/登录）。
//  2. 标题提取不再只看 vc.title：改为收集「导航栏全部文字 + titleView +
//     navigationItem」，微信自定义导航栏也能拿到「选择朋友」。
//  3. 新增结构兜底判定：有搜索框 + 有「完成/确定/下一步」按钮 + 列表够长，
//     也算多选页。
//  4. 幂等注入：每次扫描都检查按钮还在不在，微信重设导航栏后会自动补回。
//  5. 「全选」升级为「智能全选」：逐行判断是不是群聊（会话名以 @chatroom 结尾
//     或带群成员数），只勾群聊行；识别不出来时退回全选并明确告知。
//  6. 再次点击变为「取消全选」，靠自身状态判断，不依赖微信内部记录。
//
//  v8 变更（换思路：复用微信官方折叠机制，不碰内部 API）：
//  1. 新增「页面扫描」：每 1.5 秒检查当前最顶层页面，若不是已知页面则记录
//     类名/标题/行数（写进日志，用于定位真实类名）。
//  2. 识别「选择群聊」多选页（标题含"选择"为严格命中；含"添加/群聊"或类名含
//     Select 为宽松命中），自动在右上角追加「全选」按钮，不动原有的「完成」。
//  3. 「全选」= 逐行调用 tableView 的 didSelectRowAtIndexPath:，
//     复用微信自己的勾选逻辑，不改任何数据。
//  4. 严格命中的页面直接执行；宽松命中的页面先弹确认框，防误操作。
//  5. 黑名单保护：聊天窗口/主界面/设置/搜索等页面一律不注入。
//
//  v7 变更：
//  1. 新增「诊断4：折叠机制+插件环境」：
//     - 列出 App 包内所有第三方 dylib（可直接看到 Mikoto / 微信助手 等同类插件）
//     - 扫描微信自身的折叠机制类（ChatFoldViewModel / ChatFoldCellView 等），
//       目标是改用官方「折叠的群聊」API，而不是靠猜属性名。
//  2. 启动弹窗增加「同装插件」一行，冲突风险一眼可见。
//
//  v6 变更：
//  1. 全局版本号 kWFVersion：写进日志首行、启动弹窗标题、设置页入口标题。
//     装没装上，看一眼就知道，不用再猜。
//  2. 换版本时自动恢复启动弹窗（清掉「不再自动提示」的开关）。
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
#import <mach-o/dyld.h>

#pragma mark - 可配置区

static NSString * const kWFSessionMgrClass = @"MMSessionMgr";

// 版本号：日志、启动弹窗、设置页入口都会显示，用来确认新 dylib 是否真的装上
static NSString * const kWFVersion = @"v9";

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

// 找到当前最顶层的可见控制器（穿透 present / nav / tab / 容器 VC）
static UIViewController *WFDeepestVC(UIViewController *vc, int depth) {
    if (!vc || depth > 10) return vc;
    if (vc.presentedViewController) return WFDeepestVC(vc.presentedViewController, depth + 1);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top && top != vc) return WFDeepestVC(top, depth + 1);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
        if (sel && sel != vc) return WFDeepestVC(sel, depth + 1);
    }
    // 容器 VC：继续下沉到最后一个「已上屏」的子控制器
    UIViewController *last = nil;
    for (UIViewController *c in vc.childViewControllers) {
        if (c.view && c.view.window) last = c;
    }
    if (last && last != vc) return WFDeepestVC(last, depth + 1);
    return vc;
}

static UIViewController *WFTopViewController(void) {
    UIWindow *w = WFKeyWindow();
    if (!w) return nil;
    return WFDeepestVC(w.rootViewController, 0);
}

// 递归收集一段视图里的全部可见文字（UILabel / UIButton）
static void WFCollectTexts(UIView *v, NSMutableArray<NSString *> *out, int depth) {
    if (!v || depth > 8 || out.count >= 30) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length && t.length <= 40 && ![out containsObject:t]) [out addObject:t];
    } else if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)v) titleForState:UIControlStateNormal];
        if (!t.length) t = [((UIButton *)v) titleForState:UIControlStateSelected];
        if (t.length && t.length <= 40 && ![out containsObject:t]) [out addObject:t];
    }
    for (UIView *s in v.subviews) WFCollectTexts(s, out, depth + 1);
}

// 在视图树里找导航栏（微信有自定义导航栏，不一定挂在 vc.navigationController 上）
static UINavigationBar *WFFindNavBar(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UINavigationBar class]]) return (UINavigationBar *)root;
    for (UIView *s in root.subviews) {
        UINavigationBar *b = WFFindNavBar(s, depth + 1);
        if (b) return b;
    }
    return nil;
}

// 当前页面「能被用户看到的全部文字」：标题属性 + titleView + 导航栏实际文字
static NSArray<NSString *> *WFPageTexts(UIViewController *vc) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!vc) return out;
    if (vc.title.length) [out addObject:vc.title];
    NSString *nit = vc.navigationItem.title;
    if (nit.length && ![out containsObject:nit]) [out addObject:nit];
    if (vc.navigationItem.titleView) WFCollectTexts(vc.navigationItem.titleView, out, 0);

    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (!bar) {
        UIWindow *w = WFKeyWindow();
        if (w) bar = WFFindNavBar(w, 0);
    }
    if (bar) {
        WFCollectTexts(bar, out, 0);
        UINavigationItem *it = bar.topItem;
        if (it.title.length && ![out containsObject:it.title]) [out addObject:it.title];
        for (UIBarButtonItem *b in it.rightBarButtonItems) {
            if (b.title.length && ![out containsObject:b.title]) [out addObject:b.title];
        }
        if (it.rightBarButtonItem.title.length && ![out containsObject:it.rightBarButtonItem.title]) {
            [out addObject:it.rightBarButtonItem.title];
        }
    }
    return out;
}

// 带缓存的取文字：同一个页面不重复遍历视图树
static NSArray<NSString *> *WFPageTextsCached(UIViewController *vc) {
    static __weak UIViewController *cachedVC = nil;
    static NSArray<NSString *> *cachedTexts = nil;
    if (cachedVC == vc && cachedTexts.count) return cachedTexts;
    NSArray<NSString *> *t = WFPageTexts(vc);
    cachedVC = vc;
    cachedTexts = t;
    return t;
}

// 找搜索框（多选页几乎都有）
static UIView *WFFindSearchBarIn(UIView *root, int depth) {
    if (!root || depth > 9) return nil;
    if ([root isKindOfClass:[UISearchBar class]]) return root;
    NSString *cn = NSStringFromClass([root class]);
    if ([cn containsString:@"SearchBar"]) return root;
    for (UIView *s in root.subviews) {
        UIView *r = WFFindSearchBarIn(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

// 递归判断一个对象（会话 / 联系人 / 视图模型）是不是群聊
// 判据：任何一处字符串以 @chatroom 结尾，或带群成员数字段
static BOOL WFObjectHasChatroomTag(id obj, int depth) {
    if (!obj || depth > 3) return NO;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        return [s hasSuffix:@"@chatroom"] || [s hasSuffix:@"@im.chatroom"];
    }
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSNull class]]) return NO;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        if (a.count > 400) return NO;
        for (id o in a) if (WFObjectHasChatroomTag(o, depth + 1)) return YES;
        return NO;
    }
    if ([obj isKindOfClass:[NSSet class]]) {
        NSSet *st = (NSSet *)obj;
        if (st.count > 400) return NO;
        for (id o in st) if (WFObjectHasChatroomTag(o, depth + 1)) return YES;
        return NO;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        if (d.count > 200) return NO;
        for (id k in d) {
            if (WFObjectHasChatroomTag(k, depth + 1)) return YES;
            if (WFObjectHasChatroomTag(d[k], depth + 1)) return YES;
        }
        return NO;
    }
    // 普通对象：扫 @ 类型的 ivar
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([obj class], &ic);
    BOOL found = NO;
    for (unsigned int i = 0; i < ic && !found; i++) {
        const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
        if (te[0] != '@') continue;
        id v = nil;
        @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { continue; }
        if (!v || v == obj) continue;
        if (WFObjectHasChatroomTag(v, depth + 1)) found = YES;
    }
    free(ivs);
    return found;
}

// 从 dataSource 的数组 ivar 里按行取数据对象
static id WFObjectForRow(id ds, NSIndexPath *ip) {
    if (!ds || !ip) return nil;
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([ds class], &ic);
    NSArray *hit = nil;
    for (unsigned int i = 0; i < ic; i++) {
        const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
        if (te[0] != '@') continue;
        NSString *tes = [NSString stringWithUTF8String:te];
        if (!tes) continue;
        if (!([tes containsString:@"NSArray"] || [tes containsString:@"NSMutableArray"])) continue;
        id v = nil;
        @try { v = object_getIvar(ds, ivs[i]); } @catch (NSException *e) { continue; }
        if (![v isKindOfClass:[NSArray class]]) continue;
        NSArray *a = (NSArray *)v;
        if (a.count <= (NSUInteger)ip.row) continue;
        id first = [a firstObject];
        if (!first || [first isKindOfClass:[NSString class]] || [first isKindOfClass:[NSNumber class]]) continue;
        hit = a;
        break;
    }
    free(ivs);
    if (!hit || ip.section != 0) return nil;
    return hit[ip.row];
}

// 判断某一行是不是群聊：1=是  0=不是  -1=判断不出来
static NSInteger WFRowChatroomState(UITableView *tv, NSIndexPath *ip) {
    @try {
        id obj = WFObjectForRow(tv.dataSource, ip);
        if (obj) return WFObjectHasChatroomTag(obj, 0) ? 1 : 0;
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if (cell) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList([cell class], &ic);
            NSInteger st = -1;
            for (unsigned int i = 0; i < ic && st < 0; i++) {
                const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
                if (te[0] != '@') continue;
                id v = nil;
                @try { v = object_getIvar(cell, ivs[i]); } @catch (NSException *e) { continue; }
                if (!v || [v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) continue;
                NSString *vn = NSStringFromClass([v class]);
                if ([vn containsString:@"Label"] || [vn containsString:@"View"] ||
                    [vn containsString:@"Button"] || [vn containsString:@"Image"] ||
                    [vn containsString:@"Layout"] || [vn containsString:@"Layer"]) continue;
                st = WFObjectHasChatroomTag(v, 0) ? 1 : 0;
            }
            free(ivs);
            if (st >= 0) return st;
        }
    } @catch (NSException *e) { }
    return -1;
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

#pragma mark - 诊断 4：折叠机制 + 插件环境

// 列出 App 包内加载的第三方 dylib（用来发现 Mikoto / 助手 等同类插件）
static NSArray<NSString *> *WFOtherInjectedDylibs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *p = [NSString stringWithUTF8String:cname];
        if (!p.length) continue;
        if ([p hasPrefix:@"/System/"] || [p hasPrefix:@"/usr/lib/"] || [p hasPrefix:@"/Developer/"]) continue;
        if (![p containsString:@"/Application/"]) continue;   // 只看 App 包内的
        if (![p hasSuffix:@".dylib"]) continue;
        NSString *shortName = [p lastPathComponent];
        if ([shortName hasPrefix:@"lib"]) continue;
        if ([shortName isEqualToString:@"WeChatFold.dylib"]) continue;
        if (![out containsObject:shortName]) [out addObject:shortName];
    }
    return out;
}

static void WFListInjectedDylibs(void) {
    WFLOG(@"==== 已注入的插件 dylib（App 包内）====");
    NSArray<NSString *> *list = WFOtherInjectedDylibs();
    if (list.count == 0) {
        WFLOG(@"  仅本插件，没有发现其它第三方 dylib");
    } else {
        WFLOG(@"  共 %lu 个：", (unsigned long)list.count);
        for (NSString *s in list) WFLOG(@"    %@", s);
    }
    WFLOG(@"==== 插件列表结束 ====");
}

// 微信命名域前缀
static NSArray<NSString *> *WFNamespacePrefixes(void) {
    return @[@"MM", @"WC", @"WX", @"New", @"Chat", @"Base", @"Enterprise",
             @"Brand", @"Friend", @"Session", @"CContact", @"Contact", @"Converge"];
}

// 扫描微信自身的「折叠」机制（官方折叠的群聊 = ChatFoldViewModel / ChatFoldCellView）
static void WFDumpFoldClasses(void) {
    WFLOG(@"==== 折叠机制扫描 ====");
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { WFLOG(@"无法获取类列表"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned)n);
    n = objc_getClassList(classes, n);

    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        if (WFIsSwiftClassName(name)) continue;
        NSString *low = [name lowercaseString];
        if (![low containsString:@"fold"]) continue;
        for (NSString *p in WFNamespacePrefixes()) {
            if ([name hasPrefix:p]) { [targets addObject:name]; break; }
        }
    }
    free(classes);

    [targets sortUsingSelector:@selector(compare:)];
    WFLOG(@"微信域内含 Fold 的类：%lu 个", (unsigned long)targets.count);
    for (NSString *name in targets) WFLOG(@"[Fold] %@", name);

    WFLOG(@"---- 详情 ----");
    for (NSString *name in targets) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        WFLOG(@"[类] %@  父类=%@", name, NSStringFromClass(class_getSuperclass(cls)));
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc && j < 70; j++) {
            WFLOG(@"    %@", NSStringFromSelector(method_getName(ms[j])));
        }
        free(ms);
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int j = 0; j < ic && j < 30; j++) {
            WFLOG(@"    ivar %s (%s)", ivar_getName(ivs[j]) ?: "?", ivar_getTypeEncoding(ivs[j]) ?: "?");
        }
        free(ivs);
    }
    WFLOG(@"==== 折叠机制扫描结束 ====");
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
@property (nonatomic, weak) UITableView *pickerTable;
@property (nonatomic, weak) UIViewController *pickerVC;
@property (nonatomic, assign) BOOL pickerIsStrict;
@property (nonatomic, assign) BOOL selectAllDone;
@property (nonatomic, copy) NSString *pickerPageKey;
+ (instancetype)shared;
- (void)injectSettingEntry:(UIViewController *)vc;
- (void)showMenuFrom:(UIViewController *)vc;
- (void)showBootAlertOn:(UIViewController *)vc;
- (void)showLogFrom:(UIViewController *)vc;
- (void)copyLogToPasteboard;
- (void)closeLog;
- (void)alert:(NSString *)msg from:(UIViewController *)vc;
- (void)scanTopPage;
- (BOOL)isSelectListPage:(UIViewController *)vc
               tableView:(UITableView *)tv
                   texts:(NSArray<NSString *> *)texts
                isStrict:(BOOL *)strict;
- (void)onSelectAllTap;
- (NSString *)pageDisplayName:(UIViewController *)vc;
- (void)performSelectAll:(UITableView *)tv
                deselect:(BOOL)deselect
             chatroomOnly:(BOOL)chatroomOnly
                  states:(NSDictionary<NSNumber *, NSNumber *> *)states;
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
        lb.text = [NSString stringWithFormat:@"群聊批量折叠 %@", kWFVersion];
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
        WFLOG(@"设置页入口已注入 %@：%@", kWFVersion, NSStringFromClass([vc class]));
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
    UIAlertAction *diag4 = [UIAlertAction actionWithTitle:@"诊断4：折叠机制+插件环境"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发：折叠机制+插件环境 ====");
        WFListInjectedDylibs();
        WFDumpFoldClasses();
        [self alert:@"已扫描折叠机制与插件环境。点「查看日志」→「复制全部」发给我。" from:vc];
    }];
    UIAlertAction *viewLog = [UIAlertAction actionWithTitle:@"查看日志"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"清空日志"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *a) { WFClearLog(); [self alert:@"日志已清空。" from:vc]; }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [ac addAction:fold]; [ac addAction:unfold];
    [ac addAction:diag1]; [ac addAction:diag2]; [ac addAction:diag3]; [ac addAction:diag4];
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
    NSArray<NSString *> *others = WFOtherInjectedDylibs();
    [s appendFormat:@"\n同装插件：\n%@\n",
        others.count ? [others componentsJoinedByString:@"\n"] : @"（仅本插件）"];
    [s appendString:@"\n入口位置：微信 → 我 → 设置 → 页面最底部"];
    return s;
}

- (void)showBootAlertOn:(UIViewController *)vc {
    if (!vc) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WFBootAlertDisabled"]) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"WeChatFold %@", kWFVersion]
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
    WFLOG(@"启动自检弹窗已显示 %@", kWFVersion);
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

#pragma mark 页面扫描（给「选择群聊」页挂「全选」）

// 判断是不是「选择群聊 / 选择朋友」这类多选页面
- (BOOL)isSelectListPage:(UIViewController *)vc
               tableView:(UITableView *)tv
                   texts:(NSArray<NSString *> *)texts
                isStrict:(BOOL *)strict {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass([vc class]);

    // 窄黑名单：只排除真正绝对不能碰的页面
    // （v8 把 "Contact" 也列进来是错的——「选择朋友」页类名就含 Contact，被自己拦掉了）
    NSArray<NSString *> *black = @[@"MsgContent", @"BaseMsg", @"MainFrame", @"MMMain",
                                   @"TabBar", @"Setting", @"Moment", @"Sns",
                                   @"Login", @"SessionList", @"ChatList", @"Emoticon"];
    for (NSString *b in black) if ([cls containsString:b]) return NO;

    NSInteger sections = [tv numberOfSections];
    NSInteger rows = sections > 0 ? [tv numberOfRowsInSection:0] : 0;
    if (rows < 2) return NO;

    BOOL titleSelect = NO;
    for (NSString *t in texts) if ([t containsString:@"选择"]) { titleSelect = YES; break; }

    BOOL hasDone = NO;
    for (NSString *t in texts) {
        if ([t containsString:@"完成"] || [t containsString:@"确定"] ||
            [t containsString:@"下一步"] || [t containsString:@"添加"] ||
            [t containsString:@"保存"] || [t containsString:@"创建"]) { hasDone = YES; break; }
    }

    BOOL hasSearch = WFFindSearchBarIn(vc.view, 0) != nil;
    BOOL clsSelect = [cls containsString:@"Select"] || [cls containsString:@"Choose"] ||
                     [cls containsString:@"Picker"];

    BOOL isStrict = titleSelect || (clsSelect && (hasDone || hasSearch));
    BOOL isFallback = (hasDone && hasSearch && rows >= 3);

    // 同一「类名+文字」只判定记录一次，否则每 1.5 秒刷一行
    static NSMutableSet *judged = nil;
    static dispatch_once_t jOnce;
    dispatch_once(&jOnce, ^{ judged = [NSMutableSet set]; });
    NSString *jkey = [NSString stringWithFormat:@"%@|%@", cls, [texts componentsJoinedByString:@"/"]];
    if (![judged containsObject:jkey]) {
        [judged addObject:jkey];
        WFLOG(@"[判定] %@ | 分区=%ld 首区行数=%ld | 文字=[%@] | 搜索框=%@ | 选中类名=%@ | 严格=%@ 兜底=%@",
              cls, (long)sections, (long)rows, [texts componentsJoinedByString:@" / "],
              hasSearch ? @"有" : @"无", clsSelect ? @"是" : @"否",
              isStrict ? @"是" : @"否", isFallback ? @"是" : @"否");
    }

    if (!isStrict && !isFallback) return NO;
    if (strict) *strict = isStrict;
    return YES;
}

- (NSString *)pageDisplayName:(UIViewController *)vc {
    if (!vc) return @"?";
    NSArray<NSString *> *texts = WFPageTexts(vc);
    NSString *best = @"";
    for (NSString *t in texts) {
        if ([t containsString:@"选择"] || [t containsString:@"折叠"] || [t containsString:@"群聊"]) {
            best = t;
            break;
        }
    }
    if (!best.length && texts.count) best = texts.firstObject;
    return best.length ? best : NSStringFromClass([vc class]);
}

- (void)scanTopPage {
    @try {
        UIViewController *vc = WFTopViewController();
        if (!vc) return;

        self.lastVC = vc;

        NSString *cls = NSStringFromClass([vc class]);
        NSArray<NSString *> *texts = WFPageTextsCached(vc);
        UITableView *tv = WFFindTableViewIn(vc.view);
        NSInteger sections = tv ? [tv numberOfSections] : -1;
        NSInteger rows = (tv && sections > 0) ? [tv numberOfRowsInSection:0] : -1;
        BOOL hasSearch = WFFindSearchBarIn(vc.view, 0) != nil;

        // 页面记录：同一「类名+文字」只记一次，避免刷屏
        static NSMutableSet *logged = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%@|%@", cls, [texts componentsJoinedByString:@"/"]];
        if (![logged containsObject:key]) {
            [logged addObject:key];
            WFLOG(@"[页面] %@ | 分区=%ld 首区行数=%ld | 文字=[%@] | 搜索框=%@ | 列表=%@",
                  cls, (long)sections, (long)rows,
                  [texts componentsJoinedByString:@" / "], hasSearch ? @"有" : @"无",
                  tv ? @"有" : @"无");
        }

        if (!tv) return;

        BOOL strict = NO;
        if (![self isSelectListPage:vc tableView:tv texts:texts isStrict:&strict]) return;

        // 换了页面就重置「已全选」状态
        if (![key isEqualToString:self.pickerPageKey ?: @""]) {
            self.pickerPageKey = key;
            self.selectAllDone = NO;
            WFLOG(@"[命中] 多选页：%@（%@匹配，%ld 行）",
                  cls, strict ? @"严格" : @"兜底", (long)rows);
        }
        self.pickerVC = vc;
        self.pickerTable = tv;
        self.pickerIsStrict = strict;

        // 幂等注入：微信可能在我们之后重设导航栏，所以每次扫描都复查一遍
        UINavigationItem *item = vc.navigationItem;
        if (!item) return;
        NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
        if (item.rightBarButtonItems.count) [items addObjectsFromArray:item.rightBarButtonItems];
        else if (item.rightBarButtonItem) [items addObject:item.rightBarButtonItem];

        BOOL existed = NO;
        for (UIBarButtonItem *b in items) {
            if ([b.title hasPrefix:@"全选"] || [b.title hasPrefix:@"取消全选"]) { existed = YES; break; }
        }
        if (existed) return;

        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:(self.selectAllDone ? @"取消全选" : @"全选")
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(onSelectAllTap)];
        [items insertObject:btn atIndex:0];
        item.rightBarButtonItems = items;
        WFLOG(@"[注入] 已在 %@ 右上角加上「全选」（原有右上按钮 %lu 个）",
              cls, (unsigned long)(items.count - 1));
    } @catch (NSException *e) {
        WFLOG(@"页面扫描异常：%@", e.reason);
    }
}

- (void)onSelectAllTap {
    UIViewController *vc = self.pickerVC ?: WFTopViewController();
    UITableView *tv = self.pickerTable ?: (vc ? WFFindTableViewIn(vc.view) : nil);
    if (!tv) { WFLOG(@"全选：找不到列表"); return; }

    BOOL deselect = self.selectAllDone;

    // 逐行判断是不是群聊，同时统计
    NSMutableDictionary<NSNumber *, NSNumber *> *states = [NSMutableDictionary dictionary];
    NSInteger total = 0, rooms = 0, others = 0, unknown = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSInteger st = WFRowChatroomState(tv, ip);
            states[@(s * 100000 + r)] = @(st);
            total++;
            if (st > 0) rooms++; else if (st == 0) others++; else unknown++;
        }
    }

    // 一行都认不出群聊时，退回「全选所有行」，并在弹窗里如实告知
    BOOL chatroomOnly = (rooms > 0);
    WFLOG(@"全选被点击：共 %ld 行（群聊 %ld / 非群聊 %ld / 未知 %ld），页面=%@，模式=%@，动作=%@",
          (long)total, (long)rooms, (long)others, (long)unknown,
          vc ? NSStringFromClass([vc class]) : @"?", chatroomOnly ? @"只选群聊" : @"全选所有行",
          deselect ? @"取消" : @"选中");

    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"页面：%@\n", [self pageDisplayName:vc]];
    [msg appendFormat:@"共 %ld 行\n", (long)total];
    [msg appendFormat:@"识别为群聊：%ld 行\n", (long)rooms];
    if (others > 0) [msg appendFormat:@"非群聊（会跳过）：%ld 行\n", (long)others];
    if (unknown > 0) [msg appendFormat:@"无法识别：%ld 行\n", (long)unknown];
    [msg appendString:@"\n"];
    if (!chatroomOnly) {
        [msg appendString:@"⚠️ 一行都没认出是群聊，将勾选全部行。\n\n"];
    }
    [msg appendString:deselect ? @"确认取消全选？" : @"确认全选？"];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:deselect ? @"取消全选" : @"全选确认"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:(deselect ? @"取消全选" : @"执行全选")
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [self performSelectAll:tv deselect:deselect chatroomOnly:chatroomOnly states:states];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host = vc ?: WFKeyWindow().rootViewController;
    if (host) [host presentViewController:ac animated:YES completion:nil];
}

- (void)performSelectAll:(UITableView *)tv
                deselect:(BOOL)deselect
             chatroomOnly:(BOOL)chatroomOnly
                  states:(NSDictionary<NSNumber *, NSNumber *> *)states {
    id del = tv.delegate;
    BOOL hasDidSelect = del && [del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)];
    WFLOG(@"%@开始：分区=%ld，delegate=%@，实现了didSelect=%@",
          deselect ? @"取消全选" : @"全选",
          (long)[tv numberOfSections], del ? NSStringFromClass([del class]) : @"nil",
          hasDidSelect ? @"是" : @"否");
    if (!hasDidSelect) {
        WFLOG(@"该页没有实现 didSelectRowAtIndexPath:，无法用逐行点击的方式处理");
    }

    NSInteger done = 0, skipped = 0, failed = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSNumber *stNum = states[@(s * 100000 + r)];
            NSInteger st = stNum ? stNum.integerValue : -1;

            @try {
                // 只选群聊模式下，已知不是群聊的行直接跳过
                // （识别不出时 st=-1，照常处理，宁可多勾不漏勾）
                if (chatroomOnly && st == 0) { skipped++; continue; }
                // 行还没创建过就先滚到它，保证 cell 存在
                if (![tv cellForRowAtIndexPath:ip]) {
                    [tv scrollToRowAtIndexPath:ip
                                 atScrollPosition:UITableViewScrollPositionMiddle
                                         animated:NO];
                }
                if (del) [del tableView:tv didSelectRowAtIndexPath:ip];
                done++;
            } @catch (NSException *e) {
                failed++;
                WFLOG(@"行处理异常（分区%ld 第%ld 行）：%@", (long)s, (long)r, e.reason);
            }
        }
    }

    self.selectAllDone = !deselect;
    // 按钮标题跟着状态走（再次点击就变成反向操作）
    UIViewController *vc = self.pickerVC;
    UINavigationItem *item = vc.navigationItem;
    for (UIBarButtonItem *b in item.rightBarButtonItems) {
        if ([b.title hasPrefix:@"全选"]) { b.title = @"取消全选"; break; }
        if ([b.title hasPrefix:@"取消全选"]) { b.title = @"全选"; break; }
    }

    WFLOG(@"%@完成：处理 %ld 行，跳过 %ld 行（非群聊），失败 %ld 行",
          deselect ? @"取消全选" : @"全选", (long)done, (long)skipped, (long)failed);
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

static void WFStartPageScanner(void);   // 前置声明（定义在本文件末尾）

__attribute__((constructor))
static void WFEntry(void) {
    // 换版本时自动恢复启动弹窗，方便确认新 dylib 是否真的装载
    @try {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"WFSilentVersion"];
        if (!saved || ![saved isEqualToString:kWFVersion]) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"WFBootAlertDisabled"];
            [[NSUserDefaults standardUserDefaults] setObject:kWFVersion forKey:@"WFSilentVersion"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    } @catch (NSException *e) { }

    WFLOG(@"#############################");
    WFLOG(@"### WeChatFold %@ 已加载 (pid=%d) ###", kWFVersion, getpid());
    WFLOG(@"#############################");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { WFInstallHooks(); }
        @catch (NSException *e) { WFLOG(@"安装 hook 失败：%@", e.reason); }
        WFStartPageScanner();
        WFTryBootAlert(0);
    });
}

#pragma mark - 页面扫描定时器

static dispatch_source_t gWFScanner = nil;

static void WFStartPageScanner(void) {
    if (gWFScanner) return;
    gWFScanner = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gWFScanner) return;
    dispatch_source_set_timer(gWFScanner,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.5 * NSEC_PER_SEC),
                              (uint64_t)(0.3 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gWFScanner, ^{
        [[WFManager shared] scanTopPage];
    });
    dispatch_resume(gWFScanner);
    WFLOG(@"页面扫描已启动（每 1.5 秒）");
}
