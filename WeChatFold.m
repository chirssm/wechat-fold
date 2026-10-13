//
//  WeChatFold.m  v13
//  微信群聊批量折叠 —— TrollStore / 巨魔注入版
//
//  v13 变更（针对「取消全选之后过一会又被折叠」）：
//  1. 【补点不再盲点】v12 的复检补点一旦发现「状态不符」就直接再点一次，而
//     「点一下」是翻转语义 —— 万一状态读错了，这一下反而把已经取消的行重新
//     勾上，表现出来正好是「取消完过一会又被折叠」。现在补点前必须重新读一次
//     状态，确实不符才点；且只认可靠依据（cell.isSelected 是粘性信号，点过之后
//     它未必还准，一律不参与补点）。读不准就跳过，绝不盲点。
//  2. 【任务代次】每次「全选 / 取消全选 / 反选」都会作废上一个任务：旧任务残留
//     的分块执行块、补点定时块全部因代次不符而失效，不再串到新任务上互相踩。
//  3. 【收尾快照 + 回潮复查】任务结束立刻把每行「期望 / 实际 / 判定依据」写进
//     日志，并在约 4 秒、10 秒后各再读一遍。若复查时发现行自己变回已勾选，那就是
//     页面外部在改（微信自身同步或其它插件）；若一直是取消状态，则问题出在
//     「没点微信的完成」这一提交环节或外部，与本插件无关。
//  4. 完成提示语改为明确要求点微信自己的「完成」提交。
//
//  v12 变更（解决「折叠后置顶丢失」）：
//  背景：微信官方设计 —— 置顶与折叠互斥，只能二选一。把一个置顶群折叠，
//  微信会自动取消它的置顶；之后再取消折叠只移除折叠标记，绝不恢复置顶。
//  也就是说，置顶的群一旦被折叠，「置顶」就永久丢了（手动折叠也一样）。
//  对策：
//  1. 【全选跳过置顶群】执行「全选折叠」时自动跳过已置顶的群 —— 它们不参与
//     折叠，就永远不会掉置顶（微信本来也不允许置顶+折叠共存）。
//  2. 【记录 / 恢复置顶】新增「记录置顶名单」把当前所有置顶群存到本地；
//     万一已经丢过置顶，用「恢复置顶」把名单里的群重新置顶回来。
//  3. 置顶标志多来源探测：候选属性名 → 联系人对象属性 → 暴力扫名字里带
//     top / sticky 的布尔 ivar。都读不到就判「不确定」，宁可不碰。
//  4. 新增「诊断5：扫描置顶机制」，把每个群读到的置顶状态与依据写进日志。
//
//  v11 变更（修掉「只勾上一部分群、剩下的没动」）：
//  1. 【根因 1：状态误判】v10 把「认亲集合」排在状态判断的最前面，而认亲集合
//     是靠「对象身上的所有字符串」比对的，里面必然混着"群聊""折叠""勿扰"这类
//     通用词 —— 只要候选集合含一个通用词，所有行都会被判成“已勾选”，于是
//     全选一行都不点。用户看到的就是“只有原本勾着的群（＝已在折叠列表、默认
//     免打扰的群）还是勾的”。现在：
//       a) 通用词（出现在一半以上行里的字符串）全部剔除，不参与比对；
//       b) 认亲集合必须「至少两个专属字符串对上」才算命中，杜绝单词假阳性；
//       c) 一个指针都没对上时，认亲集合直接放弃判断（返回“判不出”），
//          而不是硬报“已勾选”；
//       d) 状态读取顺序反转：cell.isSelected → 系统多选集合 → accessory →
//          cell 标志 → 图标名 → 最后才是认亲集合。
//  2. 【根因 2：行对象取错】行数据对象原来只按分区号去索引 dataSource 的数组
//     成员，而那个数组列表是按 ivar 顺序出来的，不保证等于分区顺序。现在优先
//     按分区取，落空时再按“长度等于总行数的平铺数组”取。
//  3. 【群聊判定增强】新增「分区标题」判定：微信「选择朋友」页把群和人分成两个
//     区，区标题写着「群聊」「联系人」，整区定性比猜对象可靠得多。
//  4. 【点击闭环】复检发现不符的行会自动补点，最多两轮（微信的勾选回调常是
//     异步的，第一次点不生效）。
//  5. 新增「状态预览」：弹窗直接列出每行「群/人、已勾/未勾、依据、cell 文字」，
//     手机上就能看出插件读得对不对，不用翻日志。
//
//  v10 变更（修掉「全选变成反选」这个致命 bug）：
//  1. 【关键修复】页面上「点一下」是翻转语义（已勾→取消，未勾→勾上），v8/v9 把
//     每一行都点了一遍，等于把整页勾选状态整体取反。这正是用户遇到的
//     「点全选之后折叠全被取消、群聊还赖在折叠列表里」的根因。
//     现在改为：先读出每行的真实勾选状态，只点「和目标不一致」的行。
//  2. 勾选状态读取分四层：
//     a) 表格 allowsMultipleSelection + indexPathsForSelectedRows（最准，覆盖全部行）
//     b) 在页面上找「已勾选集合」容器（VC 及其逻辑对象的数组/集合成员），
//        用行对象的指针和字符串与容器比对（覆盖全部行，且不受 cell 是否已创建影响）
//     c) cell 自己的 BOOL 成员（bSelected / isChecked 之类）
//     d) 系统 accessory 勾 / 勾选框图标资源名
//     四层都判不出来时，该行直接跳过 —— 宁可不动，也不做翻转。
//  3. 新增「反选」：只对群聊行取反。
//  4. 右上角按钮改为「全选」，点击弹出操作面板：全选 / 取消全选 / 反选 / 状态自检。
//     面板里会写明行数、群聊数、当前已勾选数、以及判定依据。
//  5. 分块异步执行（每批 12 行，间隔 50ms），避免一次性点几百行导致 cell 尚未
//     创建、界面卡死。
//  6. 执行完自动复检：重新读一遍状态，把「符合 / 不符合 / 判不出」写进弹窗和日志。
//  7. 新增「状态自检」：把 cell 的 BOOL 成员、图标资源名、可见行的判定结果全
//     写进日志，一次就能定位真实字段名。
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
//     或带群成员数），只勾群聊行。
//
//  v8 变更（换思路：复用微信官方折叠机制，不碰内部 API）：
//  1. 新增「页面扫描」：每 1.5 秒检查当前最顶层页面，若不是已知页面则记录
//     类名/标题/行数（写进日志，用于定位真实类名）。
//  2. 识别多选页并在右上角追加按钮，不动原有的「完成」。
//  3. 勾选复用微信自己的 didSelectRowAtIndexPath:，不改任何数据。
//
//  零依赖：不用 CydiaSubstrate / Logos %hook，纯 Objective-C runtime。
//  仅供个人自用与学习研究。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

#pragma mark - 可配置区

static NSString * const kWFSessionMgrClass = @"MMSessionMgr";

// 版本号：日志、启动弹窗、设置页入口都会显示，用来确认新 dylib 是否真的装上
static NSString * const kWFVersion = @"v13";

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

// 「是否置顶」候选属性名（KVC 读；微信里置顶标志多半带 top / sticky）
static NSArray<NSString *> *WFTopKeys(void) {
    return @[@"m_bIsTop", @"m_bTop", @"m_bTopSession", @"m_bIsSticky",
             @"m_bSticky", @"isTop", @"m_bSessionTop", @"m_uiTopFlag",
             @"m_bTopFlag", @"m_bIsTopSession", @"m_bMarkTop",
             @"m_bConversationTop", @"m_bChatTop", @"m_bTopConversation"];
}

// 「设置置顶」候选方法名（BOOL 参数）
static NSArray<NSString *> *WFTopSelectors(void) {
    return @[@"setM_bIsTop:", @"SetTop:", @"setIsTop:", @"setTop:",
             @"setM_bTop:", @"setSticky:", @"setM_bIsSticky:",
             @"setSessionTop:", @"setM_bSessionTop:", @"markTop:",
             @"setTopSession:", @"setM_bConversationTop:"];
}

// 置顶名单在本地的存储键
static NSString * const kWF_PIN_LIST = @"WFLastPinnedList";
static NSString * const kWF_PIN_TIME = @"WFLastPinnedTime";

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

// 收集对象身上所有「装着数据对象的数组」，多分区表格按分区序号取用
static NSArray *WFDataSourceLists(id ds) {
    NSMutableArray *out = [NSMutableArray array];
    if (!ds) return out;
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([ds class], &ic);
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
        if (a.count == 0 || a.count > 20000) continue;
        id first = [a firstObject];
        if (!first || [first isKindOfClass:[NSString class]] || [first isKindOfClass:[NSNumber class]]) continue;
        [out addObject:a];
    }
    free(ivs);
    return out;
}

// 表格总行数
static NSInteger WFRowTotal(UITableView *tv) {
    NSInteger n = 0;
    if (!tv) return 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) n += [tv numberOfRowsInSection:s];
    return n;
}

// 某一行在整张表里的全局序号（跨分区累加）
static NSInteger WFGlobalRowIndex(UITableView *tv, NSIndexPath *ip) {
    NSInteger n = ip ? ip.row : 0;
    if (!tv || !ip) return n;
    for (NSInteger s = 0; s < ip.section; s++) n += [tv numberOfRowsInSection:s];
    return n;
}

// 取某一行的「候选数据对象」。
// 旧版只按 ip.section 去索引 dataSource 的数组型成员，但那个数组列表是靠遍历
// ivar 得来的，顺序不保证等于分区顺序，dataSource 里又常有别的数组（已选列表、
// 分组、搜索结果…），一旦错位，整行取到的就是别的区的对象 —— 这正是「只有一部分
// 群被认出来」的原因之一。现在改为：优先按分区取，落空时再按“平铺数组”取。
static NSArray *WFObjectCandidatesForRow(id ds, NSIndexPath *ip, NSInteger globalIndex, NSInteger total) {
    NSMutableArray *out = [NSMutableArray array];
    if (!ds || !ip) return out;
    NSArray *lists = WFDataSourceLists(ds);
    if (!lists.count) return out;

    // 来源 1：多分区 —— 一个区一个数组
    if ((NSUInteger)ip.section < lists.count) {
        NSArray *a = lists[(NSUInteger)ip.section];
        if ((NSUInteger)ip.row < a.count) {
            id o = a[(NSUInteger)ip.row];
            if (o) [out addObject:o];
        }
    }
    if (out.count) return out;      // 有结果就不混入其它来源，避免误判

    // 来源 2：平铺 —— 一个数组装下所有行，长度正好等于总行数
    if (total > 0 && globalIndex >= 0) {
        for (NSArray *a in lists) {
            if ((NSInteger)a.count != total) continue;
            if ((NSUInteger)globalIndex >= a.count) continue;
            id o = a[(NSUInteger)globalIndex];
            if (o && ![out containsObject:o]) [out addObject:o];
        }
    }
    return out;
}

// 判断某一行是不是群聊：1=是  0=不是  -1=判断不出来
static NSInteger WFRowChatroomState(UITableView *tv, NSIndexPath *ip) {
    @try {
        // 手法 0（最强）：分区标题。微信「选择朋友」页通常把群和人分成两个区，
        // 区标题写着「群聊」「联系人」，整区定性比猜对象可靠得多。
        if ([tv.dataSource respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
            id h = [tv.dataSource tableView:tv titleForHeaderInSection:ip.section];
            if ([h isKindOfClass:[NSString class]] && [(NSString *)h length]) {
                NSString *hs = (NSString *)h;
                if ([hs containsString:@"群"]) return 1;
                if ([hs containsString:@"联系人"] || [hs containsString:@"朋友"] ||
                    [hs containsString:@"好友"] || [hs containsString:@"同事"]) return 0;
            }
        }

        // 手法 1：行数据对象（含 @chatroom 即判为群）
        NSInteger total = WFRowTotal(tv);
        NSArray *cands = WFObjectCandidatesForRow(tv.dataSource, ip,
                                                  WFGlobalRowIndex(tv, ip), total);
        if (cands.count) {
            for (id o in cands) if (WFObjectHasChatroomTag(o, 0)) return 1;
            return 0;
        }

        // 手法 2（原有兜底）：扫 cell 身上挂的对象
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

#pragma mark - 勾选状态判定
//
//  这一节是整个插件的关键。页面上「点一下」是“翻转”语义（已勾→取消，未勾→勾上），
//  所以不能无脑把每一行都点一遍（那等于把整页状态取反）。
//  必须先读出每行的真实勾选状态，只点“和目标不一致”的行。

typedef NS_ENUM(NSInteger, WFSelectAction) {
    WFSelectActionAll    = 0,   // 目标：全部勾上
    WFSelectActionNone   = 1,   // 目标：全部取消
    WFSelectActionInvert = 2,   // 目标：逐行取反
};

// 取一个对象身上可用来「认亲」的字符串（会话名 / 用户名 / 群 id 等）
static NSSet<NSString *> *WFIdentityTokens(id obj, int depth) {
    NSMutableSet *out = [NSMutableSet set];
    if (!obj || depth > 2) return out;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if (s.length >= 2 && s.length <= 80) [out addObject:s];
        return out;
    }
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSNull class]]) return out;
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        NSArray *a = [obj isKindOfClass:[NSArray class]] ? (NSArray *)obj : [(NSSet *)obj allObjects];
        if (a.count > 300) return out;
        for (id o in a) {
            [out unionSet:WFIdentityTokens(o, depth + 1)];
            if (out.count > 80) break;
        }
        return out;
    }
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([obj class], &ic);
    for (unsigned int i = 0; i < ic; i++) {
        const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
        if (te[0] != '@') continue;
        id v = nil;
        @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { continue; }
        if (!v || v == obj) continue;
        [out unionSet:WFIdentityTokens(v, depth + 1)];
        if (out.count > 80) break;
    }
    free(ivs);
    return out;
}

// 统计每个「身份字符串」在全部行里出现的频率。
// 出现得太普遍的（例如“群聊”“折叠”“勿扰”“联系人”这类词、以及各种 UI 类型名）
// 一律视为通用词丢弃 —— 它们是「全选一行都不点」的元凶：只要候选集合里含有
// 任意一个通用词，所有行都会被误判成“已勾选”，于是代码认为无需点击。
static NSSet<NSString *> *WFCommonTokens(NSArray<NSSet<NSString *> *> *tokenSets) {
    NSMutableSet *out = [NSMutableSet set];
    if (tokenSets.count < 3) return out;      // 样本太小，不做过滤，免得误杀
    NSMutableDictionary<NSString *, NSNumber *> *freq = [NSMutableDictionary dictionary];
    for (NSSet<NSString *> *s in tokenSets) {
        for (NSString *t in s) freq[t] = @(freq[t].integerValue + 1);
    }
    NSInteger limit = (NSInteger)tokenSets.count / 2;
    if (limit < 2) limit = 2;
    for (NSString *t in freq) {
        if (freq[t].integerValue >= limit) [out addObject:t];   // 一半以上的行都有 → 通用词
    }
    return out;
}

// 已勾选集合的引用：把容器里的对象与字符串预先摊平，便于快速判断某行在不在里面
@interface WFSelectionRef : NSObject
@property (nonatomic, strong) NSArray *objects;
@property (nonatomic, strong) NSSet<NSString *> *strings;
@property (nonatomic, strong) NSSet<NSString *> *ignoreTokens;   // 通用词，比对时跳过
@property (nonatomic, copy)   NSString *desc;
@property (nonatomic, assign) NSInteger pointerHits;             // 指针级命中数，0 = 不可信
- (NSInteger)stateForModel:(id)model;   // 1=已勾选 0=未勾选 -1=判断不了
@end

@implementation WFSelectionRef

- (NSInteger)stateForModel:(id)model {
    if (!model || model == [NSNull null]) return -1;
    for (id o in self.objects) if (o == model) return 1;   // 指针相同，最可信
    // 一个指针都没对上，说明这个容器装的并不是当前页面的行对象。
    // 这种时候绝不能返回 0 或 1 —— 那会把整页判成“已勾选”（全选于是什么都不做）。
    // 返回 -1，让上层退回去用系统接口 / cell 状态判断。
    if (self.pointerHits <= 0) return -1;
    NSSet<NSString *> *tok = WFIdentityTokens(model, 0);
    if (!tok.count || !self.strings.count) return 0;
    NSInteger hit = 0;
    for (NSString *t in tok) {
        if ([self.ignoreTokens containsObject:t]) continue;   // 通用词不算数
        if ([self.strings containsObject:t]) hit++;
    }
    return (hit >= 2) ? 1 : 0;    // 至少两个“专属”字符串对上才算，杜绝单词假阳性
}

@end

// 递归收集 cell 里的所有图片视图
static void WFCollectImageViews(UIView *v, NSMutableArray *out, int depth) {
    if (!v || depth > 6 || out.count > 60) return;
    if ([v isKindOfClass:[UIImageView class]]) [out addObject:v];
    for (UIView *s in v.subviews) WFCollectImageViews(s, out, depth + 1);
}

// 尝试读出图片的资源名（用于识别“勾选框”图标）
static NSString *WFImageNameHint(UIImage *img) {
    if (!img) return nil;
    for (NSString *k in @[@"_name", @"name", @"_imageName", @"accessibilityIdentifier"]) {
        @try {
            id v = [img valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
        } @catch (NSException *e) { }
    }
    return nil;
}

// 在 cell（含父类）里找形如 bSelected / isChecked 的 BOOL 成员
static NSInteger WFCellBOOLState(UITableViewCell *cell, NSString **nameOut) {
    if (!cell) return -1;
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"Selected", @"selected", @"Checked", @"checked",
                 @"Chosen", @"chosen", @"Picked", @"picked",
                 @"Added", @"added", @"Tick", @"tick"];
    });
    Class cls = [cell class];
    int level = 0;
    while (cls && cls != [UITableViewCell class] && cls != [UIView class] && level < 5) {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *nm = ivar_getName(ivs[i]) ?: "";
            const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
            if (!(te[0] == 'B' || te[0] == 'c' || te[0] == 'C')) continue;
            NSString *n = [NSString stringWithUTF8String:nm];
            if (!n) continue;
            BOOL hit = NO;
            for (NSString *k in keys) if ([n containsString:k]) { hit = YES; break; }
            if (!hit) continue;
            if ([n containsString:@"Enable"] || [n containsString:@"hidden"]) continue;
            // 排除语义无关的字段，避免把高亮/悬停/免打扰当成“已勾选”
            if ([n containsString:@"highLight"] || [n containsString:@"highlight"] ||
                [n containsString:@"Hover"] || [n containsString:@"hover"] ||
                [n containsString:@"Focus"] || [n containsString:@"focus"] ||
                [n containsString:@"Mute"] || [n containsString:@"mute"] ||
                [n containsString:@"Unread"] || [n containsString:@"unread"]) continue;
            ptrdiff_t off = ivar_getOffset(ivs[i]);
            char *base = (char *)(__bridge void *)cell;
            char val = *(base + off);
            free(ivs);
            if (nameOut) *nameOut = n;
            return val ? 1 : 0;
        }
        free(ivs);
        cls = class_getSuperclass(cls);
        level++;
    }
    return -1;
}

// 靠「勾选框图标」的资源名判断状态
static NSInteger WFCellIconState(UITableViewCell *cell, NSString **howOut) {
    NSMutableArray *imgs = [NSMutableArray array];
    WFCollectImageViews(cell, imgs, 0);
    for (UIImageView *iv in imgs) {
        if (iv.hidden || !iv.image) continue;
        CGRect f = iv.frame;
        if (f.size.width < 10 || f.size.width > 40) continue;
        if (f.size.height < 10 || f.size.height > 40) continue;
        NSString *nm = WFImageNameHint(iv.image);
        if (!nm.length) continue;
        NSString *low = nm.lowercaseString;
        BOOL off = ([low containsString:@"unselect"] || [low containsString:@"uncheck"] ||
                    [low containsString:@"deselect"] || [low containsString:@"normal"] ||
                    [low containsString:@"disable"] || [low containsString:@"未选"] ||
                    [low containsString:@"off"]);
        BOOL on  = ([low containsString:@"select"] || [low containsString:@"check"] ||
                    [low containsString:@"tick"] || [low containsString:@"选中"] ||
                    [low containsString:@"勾"] || [low containsString:@"ticked"]);
        if (off) { if (howOut) *howOut = [NSString stringWithFormat:@"图标名 %@", nm]; return 0; }
        if (on)  { if (howOut) *howOut = [NSString stringWithFormat:@"图标名 %@", nm]; return 1; }
    }
    return -1;
}

// 读某一行的勾选状态：1=已勾选 0=未勾选 -1=判断不了
//
// 顺序很关键。旧版把「认亲集合」放在最前面，一旦认错集合（字符串假阳性），
// 整页都会被判成“已勾选”，于是全选一行都不点 —— 表现在界面上就是
// “只有原本就勾着的群（＝已在折叠列表里、默认免打扰的群）还是勾的”。
// 现在把最可靠的系统级证据排到前面，「认亲集合」降级为最后兜底。
static NSInteger WFRowCheckedState(UITableView *tv, NSIndexPath *ip, NSString **howOut) {
    if (!tv || !ip) return -1;

    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];

    // 1) cell.isSelected —— UITableViewCell 标准属性，微信自绘多选时一般也会设
    if (cell && cell.isSelected) {
        if (howOut) *howOut = @"cell.isSelected";
        return 1;
    }

    // 2) 系统多选集合。只有它「非空」时才能当权威依据；一个都没有，可能意味着
    //    微信压根没用这套机制，不能据此断定“全未勾选”，得继续找别的证据。
    if (tv.allowsMultipleSelection) {
        NSArray<NSIndexPath *> *sel = tv.indexPathsForSelectedRows;
        if (sel.count > 0) {
            if (howOut) *howOut = @"系统多选";
            return [sel containsObject:ip] ? 1 : 0;
        }
    }

    if (!cell) return -1;                    // 行还没被创建出来，读不了

    // 3) 系统 accessory 勾
    if (cell.accessoryType == UITableViewCellAccessoryCheckmark) {
        if (howOut) *howOut = @"accessory 勾";
        return 1;
    }

    // 4) cell 自己的 BOOL 勾选标志
    NSString *bn = nil;
    NSInteger st = WFCellBOOLState(cell, &bn);
    if (st >= 0) {
        if (howOut) *howOut = [NSString stringWithFormat:@"cell 标志 %@", bn];
        return st;
    }

    // 5) 勾选框图标名
    NSString *in = nil;
    st = WFCellIconState(cell, &in);
    if (st >= 0) { if (howOut) *howOut = in; return st; }
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

#pragma mark - 置顶逻辑
//
//  微信里「置顶」和「折叠」互斥：把一个置顶群折叠，微信会自动取消它的置顶；
//  之后再取消折叠，置顶也不会回来。所以折叠前必须先把置顶群记下来 ——
//  要么折叠时跳过它们，要么事后用名单恢复。
//  置顶标志的字段名未知，这里用「候选名 + 暴力扫 ivar」多来源探测。

// 名字像不像「置顶」标志（排除 stop / topic / tip 这类误伤）
static BOOL WFIsTopIvarName(NSString *n) {
    if (!n.length) return NO;
    NSString *low = n.lowercaseString;
    if ([low containsString:@"topic"] || [low containsString:@"stop"] ||
        [low containsString:@"tip"]) return NO;
    return ([low containsString:@"top"] || [low containsString:@"sticky"]);
}

// 该类（含父类）上到底有没有这个「键」——有方法或同名 ivar 才算。
// 先问这个再走 KVC，免得对着几百行反复抛「未知键」异常，把主线程拖住。
static BOOL WFClassHasKey(Class cls, NSString *key) {
    if (!cls || !key.length) return NO;
    static NSMutableDictionary<NSString *, NSSet<NSString *> *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    NSString *cn = NSStringFromClass(cls);
    NSSet<NSString *> *set = cache[cn];
    if (!set) {
        NSMutableSet<NSString *> *names = [NSMutableSet set];
        Class c = cls;
        int lv = 0;
        while (c && c != [NSObject class] && lv < 6) {
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned int i = 0; i < mc; i++) [names addObject:NSStringFromSelector(method_getName(ms[i]))];
            free(ms);
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList(c, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *nm = ivar_getName(ivs[i]);
                if (nm) [names addObject:[NSString stringWithUTF8String:nm]];
            }
            free(ivs);
            c = class_getSuperclass(c);
            lv++;
        }
        set = names;
        cache[cn] = set;
    }
    if ([set containsObject:key]) return YES;
    if (![key hasPrefix:@"_"]) return [set containsObject:[@"_" stringByAppendingString:key]];
    return NO;
}

// 读一个会话的置顶状态：1=置顶 0=未置顶 -1=判不出
static NSInteger WFSessionTopState(id session, NSString **howOut) {
    if (!session) return -1;

    // 1) 候选属性名（KVC 命中 ivar 或同名 getter）
    for (NSString *key in WFTopKeys()) {
        if (!WFClassHasKey([session class], key)) continue;
        id v = WFValueForKey(session, key);
        if (v && [v respondsToSelector:@selector(boolValue)]) {
            if (howOut) *howOut = [NSString stringWithFormat:@"属性 %@", key];
            return [v boolValue] ? 1 : 0;
        }
    }

    // 2) 会话挂的联系人对象上的同名属性
    for (NSString *ckey in WFContactKeys()) {
        id contact = WFValueForKey(session, ckey);
        if (!contact) continue;
        for (NSString *key in WFTopKeys()) {
            if (!WFClassHasKey([contact class], key)) continue;
            id v = WFValueForKey(contact, key);
            if (v && [v respondsToSelector:@selector(boolValue)]) {
                if (howOut) *howOut = [NSString stringWithFormat:@"联系人属性 %@", key];
                return [v boolValue] ? 1 : 0;
            }
        }
    }

    // 3) 暴力扫：名字里带 top / sticky 的布尔成员（含父类，最多 4 层）
    Class cls = [session class];
    int level = 0;
    while (cls && cls != [NSObject class] && level < 4) {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
            if (!(te[0] == 'B' || te[0] == 'c' || te[0] == 'C')) continue;
            NSString *n = [NSString stringWithUTF8String:ivar_getName(ivs[i]) ?: ""];
            if (!WFIsTopIvarName(n)) continue;
            ptrdiff_t off = ivar_getOffset(ivs[i]);
            char *base = (char *)(__bridge void *)session;
            char val = *(base + off);
            free(ivs);
            if (howOut) *howOut = [NSString stringWithFormat:@"ivar %@", n];
            return val ? 1 : 0;
        }
        free(ivs);
        cls = class_getSuperclass(cls);
        level++;
    }
    return -1;
}

// 把一个会话设为置顶 / 取消置顶：候选方法 → 候选属性 → 联系人属性
static BOOL WFApplyTopToSession(id session, BOOL top) {
    if (!session) return NO;
    for (NSString *selName in WFTopSelectors()) {
        if (WFCallWithBool(session, selName, top)) {
            WFLOG(@"置顶命中方法 -%@(%@)", selName, top ? @"YES" : @"NO");
            return YES;
        }
    }
    for (NSString *key in WFTopKeys()) {
        if (WFSetBoolForKey(session, key, top)) {
            WFLOG(@"置顶命中属性 %@ = %@", key, top ? @"YES" : @"NO");
            return YES;
        }
    }
    for (NSString *ckey in WFContactKeys()) {
        id contact = WFValueForKey(session, ckey);
        if (!contact) continue;
        for (NSString *key in WFTopKeys()) {
            if (WFSetBoolForKey(contact, key, top)) {
                WFLOG(@"置顶命中联系人属性 %@ = %@", key, top ? @"YES" : @"NO");
                return YES;
            }
        }
    }
    return NO;
}

// 取所有会话（先走服务，再退回界面）
static NSArray *WFCurrentSessions(void) {
    id mgr = WFGetSessionMgr();
    NSArray *s = mgr ? WFAllSessions(mgr) : nil;
    if (!s) s = WFSessionsFromUI();
    return s;
}

// 某一行对应的会话名（用于和置顶名单比对）
static NSString *WFRowUserNameForIndex(NSArray *models, NSInteger idx) {
    if (idx < 0 || (NSUInteger)idx >= models.count) return nil;
    id m = models[(NSUInteger)idx];
    NSString *u = WFSessionUserName(m);
    if (u.length) return u;
    for (NSString *ck in WFContactKeys()) {
        id c = WFValueForKey(m, ck);
        if (!c) continue;
        NSString *cu = WFSessionUserName(c);
        if (cu.length) return cu;
    }
    return nil;
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
@property (nonatomic, copy) NSString *pickerPageKey;
// 勾选任务上下文（分块异步执行，避免一次性点几百行把界面卡死 / cell 还没创建）
@property (nonatomic, weak) UITableView *jobTable;
@property (nonatomic, weak) UIViewController *jobVC;
@property (nonatomic, strong) NSArray<NSIndexPath *> *jobPaths;
@property (nonatomic, strong) NSArray<NSNumber *> *jobTargets;
@property (nonatomic, strong) NSArray *jobModels;
@property (nonatomic, strong) NSArray *tokenCache;
@property (nonatomic, copy) NSString *refNote;
@property (nonatomic, assign) NSInteger jobIndex;
@property (nonatomic, assign) NSInteger jobDone;
@property (nonatomic, assign) NSInteger jobAlready;
@property (nonatomic, assign) NSInteger jobSkip;
@property (nonatomic, assign) NSInteger jobFail;
@property (nonatomic, assign) NSInteger jobUnknown;
@property (nonatomic, assign) NSInteger jobAction;
@property (nonatomic, assign) NSInteger jobTotal;
@property (nonatomic, assign) NSInteger jobRooms;
@property (nonatomic, copy) NSString *jobTitle;
@property (nonatomic, assign) BOOL jobRunning;
@property (nonatomic, assign) NSInteger jobRetryRound;   // 复检不符时的补点轮次（最多 2 轮）
@property (nonatomic, assign) NSInteger jobPinned;         // 因「已置顶」被主动跳过的行数
@property (nonatomic, strong) NSSet<NSString *> *pinnedSet; // 本次全选要跳过的置顶群
@property (nonatomic, assign) NSInteger jobGeneration;      // 任务代次：新任务作废旧任务的延迟块
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
- (NSArray *)currentRowModels:(UITableView *)tv;
- (WFSelectionRef *)findSelectionRef:(UIViewController *)vc
                              models:(NSArray *)models;
- (void)startJob:(NSInteger)action table:(UITableView *)tv vc:(UIViewController *)vc;
- (void)runJobChunk;
- (void)finishJob;
- (void)jobSnapshotLog:(NSString *)tag;
- (void)scheduleDriftCheckAfter:(NSTimeInterval)delay round:(NSInteger)round;
- (void)previewRowStates:(UITableView *)tv
                      vc:(UIViewController *)vc
                     ref:(WFSelectionRef *)ref
                  models:(NSArray *)models;
- (void)dumpSelectionDiagnostics:(UITableView *)tv
                              vc:(UIViewController *)vc
                             ref:(WFSelectionRef *)ref
                          models:(NSArray *)models;
- (NSSet<NSString *> *)refreshPinnedSet;
- (void)recordPinnedListFrom:(UIViewController *)vc;
- (void)restorePinnedListFrom:(UIViewController *)vc;
- (void)scanTopMechanismFrom:(UIViewController *)vc;
- (BOOL)isPinnedRowAtIndex:(NSInteger)i models:(NSArray *)models pinSet:(NSSet<NSString *> *)pinSet;
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
    UIAlertAction *record = [UIAlertAction actionWithTitle:@"记录置顶名单（折叠前先做）"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) { [self recordPinnedListFrom:vc]; }];
    UIAlertAction *restore = [UIAlertAction actionWithTitle:@"恢复置顶（用已记录的名单）"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self restorePinnedListFrom:vc]; }];
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
    UIAlertAction *diag5 = [UIAlertAction actionWithTitle:@"诊断5：扫描置顶机制"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发：扫描置顶机制 ====");
        [self scanTopMechanismFrom:vc];
    }];
    UIAlertAction *viewLog = [UIAlertAction actionWithTitle:@"查看日志"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"清空日志"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *a) { WFClearLog(); [self alert:@"日志已清空。" from:vc]; }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [ac addAction:fold]; [ac addAction:unfold];
    [ac addAction:record]; [ac addAction:restore];
    [ac addAction:diag1]; [ac addAction:diag2]; [ac addAction:diag3]; [ac addAction:diag4]; [ac addAction:diag5];
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

#pragma mark 置顶名单（记录 / 恢复）

// 扫描当前会话，把置顶的群并进本地名单；返回并集
- (NSSet<NSString *> *)refreshPinnedSet {
    NSArray<NSString *> *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kWF_PIN_LIST];
    NSMutableSet<NSString *> *set = [NSMutableSet setWithArray:saved ?: @[]];
    NSUInteger before = set.count;
    NSArray *sessions = WFCurrentSessions();
    NSInteger pinned = 0;
    for (id s in sessions) {
        if (!WFIsChatroomSession(s)) continue;
        if (WFSessionTopState(s, NULL) != 1) continue;
        pinned++;
        NSString *u = WFSessionUserName(s);
        if (u.length) [set addObject:u];
    }
    if (set.count != before) {
        [[NSUserDefaults standardUserDefaults] setObject:set.allObjects forKey:kWF_PIN_LIST];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    WFLOG(@"置顶名单刷新：现读置顶群 %ld 个，名单共 %lu 个",
          (long)pinned, (unsigned long)set.count);
    return set;
}

// 某一行是不是「已置顶」：行对象自带标志，或会话名命中已记录的置顶名单
- (BOOL)isPinnedRowAtIndex:(NSInteger)i models:(NSArray *)models pinSet:(NSSet<NSString *> *)pinSet {
    if (i < 0 || (NSUInteger)i >= models.count) return NO;
    id m = models[(NSUInteger)i];
    if (WFSessionTopState(m, NULL) == 1) return YES;
    NSString *u = WFRowUserNameForIndex(models, i);
    if (u.length && pinSet && [pinSet containsObject:u]) return YES;
    return NO;
}

// 记录置顶名单（覆盖式快照）
- (void)recordPinnedListFrom:(UIViewController *)vc {
    NSArray *sessions = WFCurrentSessions();
    if (!sessions.count) {
        [self alert:@"拿不到会话列表，记录不了。\n\n请先在设置页点「诊断2」把日志发我。" from:vc];
        return;
    }
    NSMutableArray<NSString *> *pins = [NSMutableArray array];
    NSMutableString *detail = [NSMutableString string];
    NSInteger scanned = 0, unsure = 0;
    for (id s in sessions) {
        if (!WFIsChatroomSession(s)) continue;
        scanned++;
        NSString *how = nil;
        NSInteger st = WFSessionTopState(s, &how);
        if (st < 0) unsure++;
        if (st == 1) {
            NSString *u = WFSessionUserName(s);
            if (u.length) [pins addObject:u];
            if (detail.length < 500) [detail appendFormat:@"· %@（%@）\n", u ?: @"?", how ?: @"-"];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:pins forKey:kWF_PIN_LIST];
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kWF_PIN_TIME];
    [[NSUserDefaults standardUserDefaults] synchronize];
    WFLOG(@"==== 记录置顶名单：扫群聊 %ld 个，置顶 %lu 个，判不出 %ld 个 ====\n%@",
          (long)scanned, (unsigned long)pins.count, (long)unsure, pins);
    NSString *tail = pins.count
        ? detail
        : @"一个都没读出来。说明置顶标志的字段名还没命中，请点「诊断5：扫描置顶机制」把日志发我。";
    [self alert:[NSString stringWithFormat:@"扫描群聊 %ld 个，认出置顶 %lu 个。\n\n%@\n\n以后「全选折叠」会自动跳过这些群。",
                 (long)scanned, (unsigned long)pins.count, tail] from:vc];
}

// 用名单把群重新置顶
- (void)restorePinnedListFrom:(UIViewController *)vc {
    NSArray<NSString *> *pins = [[NSUserDefaults standardUserDefaults] arrayForKey:kWF_PIN_LIST];
    if (!pins.count) {
        [self alert:@"还没有置顶名单。\n\n请先点「记录置顶名单」；或做一次「全选折叠」，它会自动记录。" from:vc];
        return;
    }
    NSArray *sessions = WFCurrentSessions();
    if (!sessions.count) { [self alert:@"拿不到会话列表，恢复不了。" from:vc]; return; }

    NSSet<NSString *> *want = [NSSet setWithArray:pins];
    id mgr = WFGetSessionMgr();
    NSInteger matched = 0, ok = 0, already = 0, fail = 0;
    NSMutableString *failed = [NSMutableString string];
    for (id s in sessions) {
        if (!WFIsChatroomSession(s)) continue;
        NSString *u = WFSessionUserName(s);
        if (!u.length || ![want containsObject:u]) continue;
        matched++;
        if (WFSessionTopState(s, NULL) == 1) { already++; continue; }
        if (WFApplyTopToSession(s, YES)) {
            ok++;
            if (mgr) for (NSString *saveSel in WFSaveSelectors()) if (WFCallWithObject(mgr, saveSel, s, NULL)) break;
        } else {
            fail++;
            if (failed.length < 200) [failed appendFormat:@"%@ ", u];
        }
    }
    WFReloadVisibleTables();
    WFLOG(@"==== 恢复置顶：名单 %lu 个，命中会话 %ld 个，本次置顶 %ld 个，本来已置顶 %ld 个，失败 %ld 个 ====",
          (unsigned long)pins.count, (long)matched, (long)ok, (long)already, (long)fail);
    NSString *msg;
    if (matched == 0) {
        msg = [NSString stringWithFormat:@"名单里 %lu 个群，在当前会话列表里一个都没找到。\n\n可能已退群/被删，或名单是旧的。", (unsigned long)pins.count];
    } else if (ok == 0 && already == 0) {
        msg = [NSString stringWithFormat:@"找到 %ld 个群，但一个都没置顶成功（字段名没命中）。\n\n请点「诊断5」把日志发我。失败：%@", (long)matched, failed];
    } else {
        msg = [NSString stringWithFormat:@"找到 %ld 个群：\n新置顶 %ld 个\n本来就没掉 %ld 个\n失败 %ld 个\n\n列表没立刻更新的话，退回聊天页再进来看。%@",
               (long)matched, (long)ok, (long)already, (long)fail,
               fail ? [NSString stringWithFormat:@"\n\n失败：%@", failed] : @""];
    }
    [self alert:msg from:vc];
}

// 诊断5：把置顶机制读到的证据写进日志
- (void)scanTopMechanismFrom:(UIViewController *)vc {
    WFLOG(@"==== 置顶机制扫描开始 ====");
    NSArray *sessions = WFCurrentSessions();
    WFLOG(@"会话总数：%lu", (unsigned long)sessions.count);
    NSInteger shown = 0, rooms = 0;
    for (id s in sessions) {
        if (!WFIsChatroomSession(s)) continue;
        rooms++;
        if (shown < 25) {
            NSString *how = nil;
            NSInteger st = WFSessionTopState(s, &how);
            WFLOG(@"  群 %@ | 置顶=%@ | 依据=%@",
                  WFSessionUserName(s) ?: @"?", st == 1 ? @"是" : (st == 0 ? @"否" : @"?"), how ?: @"-");
            shown++;
        }
    }
    WFLOG(@"群聊共 %ld 个（上面最多列 25 个）", (long)rooms);
    for (id s in sessions) {
        if (WFIsChatroomSession(s)) { WFDumpObject(s, @"置顶扫描 Session"); break; }
    }
    WFLOG(@"==== 置顶机制扫描结束 ====");
    [self alert:@"扫描完成。点「查看日志」→ 左上角「复制全部」发我。" from:vc];
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

        // 换了页面就重新记录
        if (![key isEqualToString:self.pickerPageKey ?: @""]) {
            self.pickerPageKey = key;
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
            if ([b.title hasPrefix:@"全选"] || [b.title hasPrefix:@"取消全选"] ||
                [b.title hasPrefix:@"勾选"]) { existed = YES; break; }
        }
        if (existed) return;

        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"全选"
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

#pragma mark 勾选操作

// 把当前表格所有行的数据对象按顺序取出来，用于和「勾选集」比对
- (NSArray *)currentRowModels:(UITableView *)tv {
    NSMutableArray *a = [NSMutableArray array];
    if (!tv) return a;
    NSInteger total = WFRowTotal(tv);
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSArray *cands = WFObjectCandidatesForRow(tv.dataSource, ip,
                                                      WFGlobalRowIndex(tv, ip), total);
            id o = cands.firstObject;
            [a addObject:o ?: [NSNull null]];
        }
    }
    return a;
}

// 在页面（以及页面上的逻辑对象）里找真正的「已勾选集合」
// 过程说明写到 self.refNote，调用方按需读日志
- (WFSelectionRef *)findSelectionRef:(UIViewController *)vc
                              models:(NSArray *)models {
    if (!vc || !models.count) return nil;

    NSMutableArray *owners = [NSMutableArray arrayWithObject:vc];
    unsigned int oic = 0;
    Ivar *oivs = class_copyIvarList([vc class], &oic);
    for (unsigned int i = 0; i < oic && owners.count < 12; i++) {
        const char *te = ivar_getTypeEncoding(oivs[i]) ?: "";
        if (te[0] != '@') continue;
        id v = nil;
        @try { v = object_getIvar(vc, oivs[i]); } @catch (NSException *e) { continue; }
        if (!v || v == vc) continue;
        if ([v isKindOfClass:[UIView class]] || [v isKindOfClass:[UIViewController class]]) continue;
        if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] ||
            [v isKindOfClass:[NSDictionary class]]) continue;
        if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) continue;
        [owners addObject:v];
    }
    free(oivs);

    // 收集所有「装着对象的集合」
    NSMutableArray *cands = [NSMutableArray array];
    for (id owner in owners) {
        Class cls = [owner class];
        int level = 0;
        while (cls && cls != [NSObject class] && level < 5) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList(cls, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *te = ivar_getTypeEncoding(ivs[i]) ?: "";
                if (te[0] != '@') continue;
                id v = nil;
                @try { v = object_getIvar(owner, ivs[i]); } @catch (NSException *e) { continue; }
                NSArray *arr = nil;
                if ([v isKindOfClass:[NSArray class]]) arr = (NSArray *)v;
                else if ([v isKindOfClass:[NSSet class]]) arr = [(NSSet *)v allObjects];
                if (!arr || arr.count == 0 || arr.count > 5000) continue;
                id first = arr.firstObject;
                if (!first || [first isKindOfClass:[NSNumber class]] || [first isKindOfClass:[NSNull class]]) continue;
                NSString *nm = [NSString stringWithFormat:@"%@.%@",
                                NSStringFromClass([owner class]),
                                [NSString stringWithUTF8String:ivar_getName(ivs[i]) ?: "?"]];
                [cands addObject:@{@"name": nm ?: @"?", @"value": v, @"arr": arr}];
            }
            free(ivs);
            cls = class_getSuperclass(cls);
            level++;
        }
    }

    // 行对象的「认亲」字符串（缓存，避免每个分块重算）
    NSArray<NSSet<NSString *> *> *mt = nil;
    if (self.tokenCache && self.tokenCache.count == models.count) {
        mt = self.tokenCache;
    } else {
        NSMutableArray<NSSet<NSString *> *> *tmp = [NSMutableArray array];
        for (id m in models) {
            [tmp addObject:((m == [NSNull null]) ? [NSSet set] : WFIdentityTokens(m, 0))];
        }
        mt = tmp;
        self.tokenCache = mt;
    }
    // 通用词（“群聊”“折叠”“勿扰”之类）全部剔除，否则它们会让每一行都“对上”
    NSSet<NSString *> *ignore = WFCommonTokens(mt);

    WFSelectionRef *best = nil;
    NSInteger bestCount = NSIntegerMax;
    NSMutableString *tried = [NSMutableString string];
    for (NSDictionary *c in cands) {
        NSArray *arr = c[@"arr"];
        // 排除「行数据本身」：内容与顺序和表格完全一致，或比表格还多
        BOOL isRowList = NO;
        if ((NSUInteger)arr.count == models.count) {
            isRowList = YES;
            for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
                if (arr[(NSUInteger)i] != models[(NSUInteger)i]) { isRowList = NO; break; }
            }
        } else if (arr.count > models.count) {
            isRowList = YES;
        }
        if (isRowList) continue;

        NSMutableArray *objs = [NSMutableArray array];
        NSMutableSet<NSString *> *strs = [NSMutableSet set];
        for (id e in arr) {
            if ([e isKindOfClass:[NSString class]]) [strs addObject:(NSString *)e];
            else if (e && ![e isKindOfClass:[NSNumber class]]) [objs addObject:e];
        }
        if (!objs.count && !strs.count) continue;

        NSInteger ptrHits = 0, strHits = 0;
        for (id o in objs) for (id m in models) if (m == o) { ptrHits++; break; }
        for (NSSet<NSString *> *t in mt) {
            if (!t.count) continue;
            NSInteger h = 0;
            for (NSString *s in t) {
                if ([ignore containsObject:s]) continue;   // 通用词不算数
                if ([strs containsObject:s]) h++;
            }
            if (h >= 2) strHits++;                          // 至少两个“专属”字符串才算一行对上
        }
        [tried appendFormat:@"%@=指针%ld/文字%ld/%lu项 ", c[@"name"],
              (long)ptrHits, (long)strHits, (unsigned long)arr.count];
        if (ptrHits <= 0 && strHits <= 0) continue;
        // 准入：要么有指针级命中，要么文字命中覆盖多数行。
        // 门槛一松，就会把「全部好友」「全部分组」这类集合误当成勾选集。
        if (ptrHits <= 0 && strHits * 2 < (NSInteger)models.count) continue;

        WFSelectionRef *ref = [[WFSelectionRef alloc] init];
        ref.objects = objs;
        ref.strings = strs;
        ref.ignoreTokens = ignore;
        ref.pointerHits = ptrHits;
        ref.desc = [NSString stringWithFormat:@"%@（%lu 项，指针对上 %ld，文字对上 %ld）",
                    c[@"name"], (unsigned long)arr.count, (long)ptrHits, (long)strHits];
        BOOL better = NO;
        if (!best) better = YES;
        else if (ptrHits > 0 && best.pointerHits <= 0) better = YES;
        else if ((ptrHits > 0) == (best.pointerHits > 0) && (NSInteger)arr.count < bestCount) better = YES;
        if (better) { bestCount = (NSInteger)arr.count; best = ref; }
    }

    NSMutableString *note = [NSMutableString string];
    [note appendFormat:@"候选集合：%@\n", tried.length ? tried : @"(无)"];
    [note appendFormat:@"已剔除通用词 %lu 个\n", (unsigned long)ignore.count];
    [note appendFormat:@"采用：%@", best ? best.desc : @"(无，退回逐个 cell 判断)"];
    self.refNote = note;
    return best;
}

- (void)onSelectAllTap {
    UIViewController *vc = self.pickerVC ?: WFTopViewController();
    UITableView *tv = self.pickerTable ?: (vc ? WFFindTableViewIn(vc.view) : nil);
    if (!tv) { WFLOG(@"勾选：找不到列表"); [self alert:@"这个页面里找不到列表，没法操作。" from:vc]; return; }
    if (self.jobRunning) { [self alert:@"上一次操作还在执行，等几秒再点。" from:vc]; return; }

    id del = tv.delegate;
    if (!del || ![del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        [self alert:@"这个页面没有逐行勾选的能力，插件动不了它。" from:vc];
        return;
    }

    NSArray *models = [self currentRowModels:tv];
    self.tokenCache = nil;                 // 每进一次面板都重算，避免串页
    WFSelectionRef *ref = [self findSelectionRef:vc models:models];
    if (self.refNote.length) WFLOG(@"%@", self.refNote);

    // 已置顶的群：名单命中 或 行对象自带置顶标志 —— 全选时会跳过它们
    NSArray<NSString *> *pinList = [[NSUserDefaults standardUserDefaults] arrayForKey:kWF_PIN_LIST];
    NSSet<NSString *> *pinSet = pinList.count ? [NSSet setWithArray:pinList] : nil;
    NSInteger pinnedRows = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSInteger gi = WFGlobalRowIndex(tv, [NSIndexPath indexPathForRow:r inSection:s]);
            if ([self isPinnedRowAtIndex:gi models:models pinSet:pinSet]) pinnedRows++;
        }
    }

    NSInteger total = 0, rooms = 0, others = 0, unknownRoom = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSInteger st = WFRowChatroomState(tv, [NSIndexPath indexPathForRow:r inSection:s]);
            total++;
            if (st > 0) rooms++; else if (st == 0) others++; else unknownRoom++;
        }
    }

    NSInteger checked = 0, unknowable = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSString *how = nil;
            NSInteger st = WFRowCheckedState(tv, ip, &how);        // 可靠来源优先
            if (st < 0 && ref) {
                NSInteger gi = WFGlobalRowIndex(tv, ip);
                if ((NSUInteger)gi < models.count) st = [ref stateForModel:models[(NSUInteger)gi]];
            }
            if (st == 1) checked++; else if (st < 0) unknowable++;
        }
    }

    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"页面：%@\n", [self pageDisplayName:vc]];
    [msg appendFormat:@"共 %ld 行，识别为群聊 %ld 行\n", (long)total, (long)rooms];
    if (others) [msg appendFormat:@"非群聊 %ld 行（不会碰）\n", (long)others];
    if (unknownRoom) [msg appendFormat:@"群聊判断不确定 %ld 行\n", (long)unknownRoom];
    if (pinnedRows) [msg appendFormat:@"已置顶 %ld 行（全选会跳过，避免掉置顶）\n", (long)pinnedRows];
    if (!pinList.count) [msg appendString:@"⚠️ 还没记录置顶名单，折叠置顶群会永久丢置顶\n"];
    if (ref) {
        [msg appendFormat:@"当前已勾选 %ld 行\n", (long)checked];
        if (unknowable) [msg appendFormat:@"状态判不出 %ld 行（这些行不会动）\n", (long)unknowable];
        [msg appendFormat:@"判定依据：%@", ref.desc];
    } else {
        [msg appendFormat:@"当前已勾选 %ld 行\n", (long)checked];
        if (unknowable) [msg appendFormat:@"状态判不出 %ld 行（这些行不会动）\n", (long)unknowable];
        [msg appendString:@"判定依据：逐个 cell 判断"];
    }
    WFLOG(@"勾选面板：%ld 行（群聊 %ld / 非群聊 %ld / 不确定 %ld），已勾选 %ld，依据=%@",
          (long)total, (long)rooms, (long)others, (long)unknownRoom, (long)checked,
          ref ? ref.desc : @"仅可见行");

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"群聊勾选"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak WFManager *wself = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"全选（只勾群聊、跳过已置顶）"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
        // 名单还空着（第一次用）：先自动记一次，免得折叠把置顶吃掉
        NSArray *cur = [[NSUserDefaults standardUserDefaults] arrayForKey:kWF_PIN_LIST];
        if (!cur.count) [wself refreshPinnedSet];
        [wself startJob:WFSelectActionAll table:tv vc:vc];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消全选（只取消群聊）"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
        [wself startJob:WFSelectActionNone table:tv vc:vc];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"反选（群聊行取反）"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
        [wself startJob:WFSelectActionInvert table:tv vc:vc];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"状态预览（看插件读到了什么）"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
        [wself previewRowStates:tv vc:vc ref:ref models:models];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"状态自检（写进日志）"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
        [wself dumpSelectionDiagnostics:tv vc:vc ref:ref models:models];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 上 ActionSheet 必须有锚点
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = vc.view ?: tv;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(tv.bounds),
                                                                    CGRectGetHeight(tv.bounds) - 1, 1, 1);
    }
    UIViewController *host = vc ?: WFKeyWindow().rootViewController;
    if (host) [host presentViewController:sheet animated:YES completion:nil];
}

- (void)startJob:(NSInteger)action table:(UITableView *)tv vc:(UIViewController *)vc {
    // 作废上一个还在跑的任务：它的分块块 / 补点块随后会因代次不符而失效，
    // 不会再串到这次的新任务上互相踩（这正是「全选完立刻取消全选」的隐患）
    if (self.jobRunning) WFLOG(@"上一个任务「%@」还在执行，先作废", self.jobTitle ?: @"?");
    self.jobRunning = NO;
    self.jobGeneration++;

    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    NSMutableArray<NSNumber *> *roomStates = [NSMutableArray array];
    NSArray *models = [self currentRowModels:tv];
    NSArray<NSString *> *pinList = [[NSUserDefaults standardUserDefaults] arrayForKey:kWF_PIN_LIST];
    NSSet<NSString *> *pinSet = pinList.count ? [NSSet setWithArray:pinList] : nil;
    self.pinnedSet = pinSet;
    NSInteger total = 0, rooms = 0, others = 0, unknown = 0;
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSInteger st = WFRowChatroomState(tv, ip);
            [paths addObject:ip];
            [roomStates addObject:@(st)];
            total++;
            if (st > 0) rooms++; else if (st == 0) others++; else unknown++;
        }
    }
    if (total == 0) { [self alert:@"列表是空的，没有可操作的行。" from:vc]; return; }

    BOOL chatroomOnly = (rooms > 0);
    NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
    NSInteger pinnedSkip = 0;
    for (NSInteger i = 0; i < total; i++) {
        NSInteger st = [roomStates[(NSUInteger)i] integerValue];
        if (chatroomOnly && st == 0) { [targets addObject:@(-1)]; continue; }   // 非群聊行不动
        if (action == WFSelectActionAll) {
            // 已置顶的群直接跳过：微信里折叠会取消置顶，而且不可恢复
            if ([self isPinnedRowAtIndex:i models:models pinSet:pinSet]) {
                [targets addObject:@(-3)];
                pinnedSkip++;
                continue;
            }
            [targets addObject:@(1)];
        }
        else if (action == WFSelectActionNone) [targets addObject:@(0)];
        else [targets addObject:@(-2)];                                        // 反选：运行时取反
    }
    self.jobPinned = pinnedSkip;

    self.jobTable = tv;
    self.jobVC = vc;
    self.jobPaths = paths;
    self.jobTargets = targets;
    self.jobModels = models;
    self.tokenCache = nil;
    self.jobIndex = 0;
    self.jobRetryRound = 0;
    self.jobDone = self.jobAlready = self.jobSkip = self.jobFail = self.jobUnknown = 0;
    self.jobAction = action;
    self.jobTotal = total;
    self.jobRooms = rooms;
    self.jobTitle = (action == WFSelectActionAll ? @"全选" :
                     (action == WFSelectActionNone ? @"取消全选" : @"反选"));
    self.jobRunning = YES;

    WFLOG(@"==== %@ 开始：共 %ld 行（群聊 %ld / 非群聊 %ld / 不确定 %ld），已置顶跳过 %ld 行，范围=%@ ====",
          self.jobTitle, (long)total, (long)rooms, (long)others, (long)unknown, (long)pinnedSkip,
          chatroomOnly ? @"只处理群聊行" : @"一行群聊都没认出，退化为处理全部行");
    [self runJobChunk];
}

- (void)runJobChunk {
    UITableView *tv = self.jobTable;
    if (!tv || !self.jobRunning) { self.jobRunning = NO; return; }
    NSInteger gen = self.jobGeneration;

    // 每个分块重新找一次勾选集 —— 微信可能每勾一次就换一个新数组
    WFSelectionRef *ref = [self findSelectionRef:self.jobVC models:self.jobModels];
    if (self.jobIndex == 0 && self.refNote.length) WFLOG(@"%@", self.refNote);

    id del = tv.delegate;
    NSInteger total = (NSInteger)self.jobTargets.count;
    NSInteger end = MIN(self.jobIndex + 12, total);
    NSMutableArray<NSNumber *> *targets = (NSMutableArray<NSNumber *> *)self.jobTargets;

    for (NSInteger i = self.jobIndex; i < end; i++) {
        NSIndexPath *ip = self.jobPaths[(NSUInteger)i];
        NSInteger target = [targets[(NSUInteger)i] integerValue];
        if (target == -1) { self.jobSkip++; continue; }
        if (target == -3) { continue; }        // 已置顶行：早已计入 jobPinned，不动

        @try {
            // 微信的勾选回调多半会去取 cell，所以先保证 cell 存在
            if (![tv cellForRowAtIndexPath:ip]) {
                [tv scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                [tv layoutIfNeeded];
            }

            NSString *how = nil;
            NSInteger cur = -1;
            cur = WFRowCheckedState(tv, ip, &how);          // 可靠来源优先
            if (cur < 0 && ref && (NSUInteger)i < self.jobModels.count)
                cur = [ref stateForModel:self.jobModels[(NSUInteger)i]];   // 认亲集合只作兜底
            // 状态判不出来就绝对不动它 —— 盲目点击 = 把状态翻转，正是之前的 bug
            if (cur < 0) { self.jobUnknown++; continue; }

            if (target == -2) target = (cur == 1) ? 0 : 1;
            targets[(NSUInteger)i] = @(target);          // 记录实际目标，供复检用

            if (cur == target) { self.jobAlready++; continue; }
            if (del) [del tableView:tv didSelectRowAtIndexPath:ip];
            self.jobDone++;
        } @catch (NSException *e) {
            self.jobFail++;
            WFLOG(@"第 %ld 行处理异常：%@", (long)i, e.reason);
        }
    }

    self.jobIndex = end;
    if (self.jobIndex < total) {
        __weak WFManager *wself = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WFManager *sself = wself;
            // 代次不符 = 这个块属于已被作废的旧任务，直接丢弃
            if (!sself || sself.jobGeneration != gen || !sself.jobRunning) return;
            [sself runJobChunk];
        });
    } else {
        [self finishJob];
    }
}

- (void)finishJob {
    UITableView *tv = self.jobTable;

    WFSelectionRef *ref = [self findSelectionRef:self.jobVC models:self.jobModels];

    NSMutableArray<NSNumber *> *retry = [NSMutableArray array];
    NSInteger ok = 0, bad = 0, unknown = 0, unreliable = 0;
    if (tv) {
        for (NSInteger i = 0; i < (NSInteger)self.jobTargets.count; i++) {
            NSInteger target = [self.jobTargets[(NSUInteger)i] integerValue];
            if (target < 0) continue;
            NSIndexPath *ip = self.jobPaths[(NSUInteger)i];
            NSString *how = nil;
            NSInteger cur = WFRowCheckedState(tv, ip, &how);          // 可靠来源优先
            if (cur < 0 && ref && (NSUInteger)i < self.jobModels.count)
                cur = [ref stateForModel:self.jobModels[(NSUInteger)i]];
            if (cur < 0) { unknown++; continue; }
            if (cur == target) { ok++; continue; }
            bad++;
            // 只有「依据可靠」的行才进补点队列。
            // cell.isSelected 是粘性信号（点过一次就常驻为真），拿它去补点
            // 等于闭着眼翻转 —— 万一读错，反而把已取消的行重新勾上。
            if ([how isEqualToString:@"cell.isSelected"]) { unreliable++; continue; }
            [retry addObject:@(i)];
        }
    }
    if (unreliable) WFLOG(@"复检：%ld 行状态不符但依据是粘性信号 cell.isSelected，不敢补点", (long)unreliable);

    // 复检不符的行再补点一轮 —— 微信的勾选回调经常是异步的，第一次点不生效。
    // 补点前必须重新读一次真实状态，确实不符才点。
    if (tv && retry.count > 0 && self.jobRetryRound < 2) {
        self.jobRetryRound++;
        WFLOG(@"复检不符 %ld 行（可补点 %lu 行），补第 %ld 轮",
              (long)bad, (unsigned long)retry.count, (long)self.jobRetryRound);
        id del = tv.delegate;
        for (NSNumber *n in retry) {
            NSInteger i = n.integerValue;
            @try {
                NSIndexPath *ip = self.jobPaths[(NSUInteger)i];
                if (![tv cellForRowAtIndexPath:ip]) {
                    [tv scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                    [tv layoutIfNeeded];
                }
                // 关键：点之前再读一次。已经对上了就不点，读不准也不点。
                NSInteger target = [self.jobTargets[(NSUInteger)i] integerValue];
                NSString *how2 = nil;
                NSInteger cur2 = WFRowCheckedState(tv, ip, &how2);
                if (cur2 < 0) { self.jobUnknown++; continue; }
                if (cur2 == target) continue;
                if ([how2 isEqualToString:@"cell.isSelected"]) continue;   // 依据不可靠，宁可不动
                if (del) [del tableView:tv didSelectRowAtIndexPath:ip];
                self.jobDone++;
            } @catch (NSException *e) {
                self.jobFail++;
                WFLOG(@"补点第 %ld 行异常：%@", (long)i, e.reason);
            }
        }
        NSInteger gen = self.jobGeneration;
        __weak WFManager *wself = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WFManager *sself = wself;
            if (!sself || sself.jobGeneration != gen || !sself.jobRunning) return;
            [sself finishJob];
        });
        return;                     // 保持 jobRunning，避免补点期间被重复触发
    }

    self.jobRunning = NO;

    // 收尾快照 + 回潮复查：任务刚结束的状态，以及 4 秒 / 10 秒后有没有自己变回去
    [self jobSnapshotLog:[NSString stringWithFormat:@"%@ 刚结束", self.jobTitle ?: @"任务"]];
    [self scheduleDriftCheckAfter:4.0 round:1];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ 完成\n\n", self.jobTitle];
    [s appendFormat:@"实际点击：%ld 行\n", (long)self.jobDone];
    [s appendFormat:@"本来就是目标状态：%ld 行\n", (long)self.jobAlready];
    if (self.jobSkip) [s appendFormat:@"非群聊跳过：%ld 行\n", (long)self.jobSkip];
    if (self.jobPinned) [s appendFormat:@"已置顶跳过（避免掉置顶）：%ld 行\n", (long)self.jobPinned];
    if (self.jobUnknown) [s appendFormat:@"状态判不出、没动它：%ld 行\n", (long)self.jobUnknown];
    if (self.jobFail) [s appendFormat:@"执行出错：%ld 行\n", (long)self.jobFail];
    [s appendFormat:@"\n复检：符合 %ld 行", (long)ok];
    if (bad) [s appendFormat:@"，不符合 %ld 行", (long)bad];
    if (unknown) [s appendFormat:@"，判不出 %ld 行", (long)unknown];
    if (unreliable) [s appendFormat:@"\n依据太弱、没敢补点：%ld 行", (long)unreliable];
    [s appendString:@"\n\n"];
    if (bad == 0 && self.jobFail == 0 && self.jobUnknown == 0) {
        [s appendString:@"⚠️ 必须点微信自己的「完成」才会提交保存，只返回不点等于没改。"];
    } else {
        [s appendString:@"有对不上的地方。请「查看日志」→「复制全部」发我。"];
    }

    WFLOG(@"==== %@ 结果：点击 %ld / 已对 %ld / 跳过 %ld / 未知 %ld / 失败 %ld | 复检 符合 %ld 不符 %ld 未知 %ld ====",
          self.jobTitle, (long)self.jobDone, (long)self.jobAlready, (long)self.jobSkip,
          (long)self.jobUnknown, (long)self.jobFail, (long)ok, (long)bad, (long)unknown);

    [self alert:s from:WFTopViewController()];
}

// 把「每行期望什么、实际读到什么、依据是什么」写进日志。
// 任务刚结束时调用一次，之后延迟再调用两次 —— 用来判断「取消完又自己变回勾选」
// 到底是不是本插件干的：刚结束时是取消状态、过几秒自己变回勾选 → 一定是外部。
- (void)jobSnapshotLog:(NSString *)tag {
    UITableView *tv = self.jobTable;
    if (!tv || !self.jobPaths.count || self.jobPaths.count != self.jobTargets.count) {
        WFLOG(@"[快照] %@：页面已离开或列表结构变了，本次不复查", tag);
        return;
    }

    WFSelectionRef *ref = [self findSelectionRef:self.jobVC models:self.jobModels];
    NSInteger match = 0, mismatch = 0, unknowable = 0;
    NSMutableString *det = [NSMutableString string];

    for (NSInteger i = 0; i < (NSInteger)self.jobTargets.count; i++) {
        NSInteger target = [self.jobTargets[(NSUInteger)i] integerValue];
        if (target < 0) continue;                    // 跳过 / 置顶保护行不参与
        NSIndexPath *ip = self.jobPaths[(NSUInteger)i];
        NSString *how = nil;
        NSInteger cur = WFRowCheckedState(tv, ip, &how);
        if (cur < 0 && ref && (NSUInteger)i < self.jobModels.count)
            cur = [ref stateForModel:self.jobModels[(NSUInteger)i]];
        if (cur < 0) { unknowable++; continue; }
        if (cur == target) { match++; continue; }
        mismatch++;
        [det appendFormat:@"    第 %ld 行：期望%@ 实际%@（依据 %@）\n",
                          (long)i, target ? @"勾选" : @"取消", cur ? @"勾选" : @"取消", how ?: @"认亲集合"];
    }

    WFLOG(@"[快照] %@ → 符合 %ld / 不符 %ld / 判不出 %ld（当前勾选动作＝%@）",
          tag, (long)match, (long)mismatch, (long)unknowable, self.jobTitle ?: @"?");
    if (det.length) WFLOG(@"[快照] 不符明细：\n%@", det);
}

// 回潮复查：延迟若干秒后再读一遍状态，看有没有行自己变回「已勾选」。
// 4 秒一次、再 6 秒一次（累计约 10 秒），两次都写日志。
- (void)scheduleDriftCheckAfter:(NSTimeInterval)delay round:(NSInteger)round {
    NSInteger gen = self.jobGeneration;
    __weak WFManager *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WFManager *sself = wself;
        if (!sself || sself.jobGeneration != gen) return;   // 期间又开了新任务就不查了
        NSInteger shown = (round == 1) ? 4 : 10;            // 与下面的 4s / 6s 调度对应
        [sself jobSnapshotLog:[NSString stringWithFormat:@"%@ 结束后 +%ld 秒复查",
                               sself.jobTitle ?: @"任务", (long)shown]];
        if (round >= 2) return;
        WFManager *sself2 = wself;
        if (sself2) [sself2 scheduleDriftCheckAfter:6.0 round:round + 1];
    });
}

// 状态预览：把插件「读到了什么」直接显示在手机上，不用翻日志。
// 每行给出：分区-行号 / 群还是人 / 勾选状态 / 判断依据 / cell 上的文字
- (void)previewRowStates:(UITableView *)tv
                      vc:(UIViewController *)vc
                     ref:(WFSelectionRef *)ref
                  models:(NSArray *)models {
    if (!tv) { [self alert:@"找不到列表" from:vc]; return; }

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"列表：%@（%ld 个分区）\n",
          NSStringFromClass([tv class]), (long)[tv numberOfSections]];
    [s appendFormat:@"勾选集依据：%@\n\n", ref ? ref.desc : @"(无，逐个 cell 判断)"];

    NSInteger total = WFRowTotal(tv);
    NSInteger shown = 0;
    for (NSInteger sec = 0; sec < [tv numberOfSections]; sec++) {
        if ([tv.dataSource respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
            id h = [tv.dataSource tableView:tv titleForHeaderInSection:sec];
            if ([h isKindOfClass:[NSString class]] && [(NSString *)h length])
                [s appendFormat:@"— 分区%ld 标题「%@」—\n", (long)sec, h];
        }
        NSInteger rowsInSec = [tv numberOfRowsInSection:sec];
        for (NSInteger r = 0; r < rowsInSec && shown < 15; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:sec];
            NSInteger room = WFRowChatroomState(tv, ip);
            NSString *how = nil;
            NSInteger st = WFRowCheckedState(tv, ip, &how);
            if (st < 0 && ref) {
                NSInteger gi = WFGlobalRowIndex(tv, ip);
                if ((NSUInteger)gi < models.count) {
                    st = [ref stateForModel:models[(NSUInteger)gi]];
                    how = @"认亲集合";
                }
            }
            UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
            NSMutableArray<NSString *> *txts = [NSMutableArray array];
            if (cell) WFCollectTexts(cell, txts, 0);
            NSString *brief = txts.count ? [txts componentsJoinedByString:@"|"] : @"";
            if (brief.length > 34) brief = [[brief substringToIndex:34] stringByAppendingString:@"…"];
            [s appendFormat:@"%ld-%ld %@ %@ [%@]%@\n",
                  (long)sec, (long)r,
                  room > 0 ? @"群" : (room == 0 ? @"人" : @"?"),
                  st == 1 ? @"已勾" : (st == 0 ? @"未勾" : @"判不出"),
                  how.length ? how : @"-",
                  brief.length ? [@" " stringByAppendingString:brief] : @""];
            shown++;
        }
    }
    if (total > shown) [s appendFormat:@"…还有 %ld 行，请看日志\n", (long)(total - shown)];

    WFLOG(@"==== 状态预览 ====\n%@", s);
    [self alert:s from:vc];
}

// 状态自检：把「怎么判断勾选状态」的证据全写进日志，方便一次定位
- (void)dumpSelectionDiagnostics:(UITableView *)tv
                              vc:(UIViewController *)vc
                             ref:(WFSelectionRef *)ref
                          models:(NSArray *)models {
    WFLOG(@"==== 勾选状态自检开始 ====");
    WFLOG(@"表格 %@ | 分区=%ld | allowsMultipleSelection=%@ | delegate=%@",
          NSStringFromClass([tv class]), (long)[tv numberOfSections],
          tv.allowsMultipleSelection ? @"是" : @"否",
          tv.delegate ? NSStringFromClass([tv.delegate class]) : @"nil");
    WFLOG(@"勾选集引用：%@", ref ? ref.desc : @"(无，退回逐个 cell 判断)");

    NSArray<NSIndexPath *> *vis = [tv indexPathsForVisibleRows];
    WFLOG(@"可见行 %lu 个", (unsigned long)vis.count);
    NSInteger limit = MIN((NSInteger)vis.count, 25);
    for (NSInteger i = 0; i < limit; i++) {
        NSIndexPath *ip = vis[(NSUInteger)i];
        NSString *how = nil;
        NSInteger st = WFRowCheckedState(tv, ip, &how);
        NSInteger room = WFRowChatroomState(tv, ip);
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        WFLOG(@"  行 %ld-%ld | 群聊=%@ | 勾选=%@ | 依据=%@ | cell=%@",
              (long)ip.section, (long)ip.row,
              room > 0 ? @"是" : (room == 0 ? @"否" : @"?"),
              st == 1 ? @"已勾" : (st == 0 ? @"未勾" : @"?"),
              how ?: @"-", cell ? NSStringFromClass([cell class]) : @"nil");
    }

    UITableViewCell *cell = nil;
    if ([tv numberOfSections] > 0 && [tv numberOfRowsInSection:0] > 0) {
        cell = [tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    }
    if (cell) {
        WFLOG(@"---- cell 细节：%@ ----", NSStringFromClass([cell class]));
        Class cls = [cell class];
        int level = 0;
        while (cls && cls != [NSObject class] && level < 4) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList(cls, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *te = ivar_getTypeEncoding(ivs[i]) ?: "?";
                char t0 = te[0];
                if (!(t0 == 'B' || t0 == 'c' || t0 == 'C' || t0 == 'i' || t0 == 'q' || t0 == 'Q')) continue;
                char *base = (char *)(__bridge void *)cell;
                ptrdiff_t off = ivar_getOffset(ivs[i]);
                long long val = 0;
                if (t0 == 'B' || t0 == 'c' || t0 == 'C') val = (long long)(*(char *)(base + off));
                else if (t0 == 'i') { int t = 0; memcpy(&t, base + off, sizeof(t)); val = t; }
                else { long long t = 0; memcpy(&t, base + off, sizeof(t)); val = t; }
                WFLOG(@"    %s (%s) = %lld", ivar_getName(ivs[i]) ?: "?", te, val);
            }
            free(ivs);
            cls = class_getSuperclass(cls);
            level++;
        }
        NSMutableArray *imgs = [NSMutableArray array];
        WFCollectImageViews(cell, imgs, 0);
        WFLOG(@"    图片视图 %lu 个", (unsigned long)imgs.count);
        for (UIImageView *iv in imgs) {
            NSString *nm = WFImageNameHint(iv.image);
            if (!nm) continue;
            WFLOG(@"      %@ 图名=%@ hidden=%@ frame=%@",
                  NSStringFromClass([iv class]), nm, iv.hidden ? @"是" : @"否",
                  NSStringFromCGRect(iv.frame));
        }
    }
    WFLOG(@"==== 勾选状态自检结束 ====");
    [self alert:@"自检已写进日志。点「查看日志」→ 左上角「复制全部」发我。" from:vc];
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
