//
//  WeChatFold.m  v3
//  微信群聊批量折叠 —— TrollStore / 巨魔注入版
//
//  v3 变更：
//  1. 启动即弹窗自检：dylib 一加载就主动弹窗报到，显示 hook 结果与会话探测结果，
//     解决「按钮没出现就无法诊断」的死结。
//  2. 微信设置页注入入口：在设置列表底部追加一行「群聊批量折叠」，
//     通过 tableFooterView 实现，不动 dataSource，风险低。
//  3. 多候选类名：主界面与设置页各有一串候选类名，命中哪个 hook 哪个。
//
//  零依赖：不用 CydiaSubstrate / Logos %hook，纯 Objective-C runtime。
//  仅供个人自用与学习研究。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 可配置区

static NSString * const kWFSessionMgrClass = @"MMSessionMgr";

// 主界面候选类名
static NSArray<NSString *> *WFMainFrameCandidates(void) {
    return @[@"MainFrameViewController",
             @"MMMainTabViewController",
             @"MMMainViewController",
             @"WMMainViewController",
             @"MMTabBarController",
             @"WMTabBarController"];
}

// 设置页候选类名
static NSArray<NSString *> *WFSettingCandidates(void) {
    return @[@"NewSettingViewController",
             @"WCSettingViewController",
             @"MMSettingViewController",
             @"MoreViewController",
             @"MMMoreViewController",
             @"WXSettingViewController",
             @"SettingViewController"];
}

// 会话列表候选方法名
static NSArray<NSString *> *WFSessionListSelectors(void) {
    return @[@"getAllSessions", @"GetAllSession", @"getSessionList",
             @"getAllSessionInfo", @"getSessions", @"GetSessionList"];
}

// 会话列表候选属性名
static NSArray<NSString *> *WFSessionListKeys(void) {
    return @[@"m_arrSession", @"m_arrSessionInfo", @"m_sessionList", @"arrSession"];
}

// 「是否折叠」候选属性名（KVC 写入）
static NSArray<NSString *> *WFFoldKeys(void) {
    return @[@"m_bIsFoldSession", @"m_bFolded", @"m_bIsFold",
             @"m_bShowInFoldList", @"m_uiFoldSessionFlag",
             @"m_bFoldSession", @"m_bInFoldSessionList"];
}

// 「设置折叠」候选方法名（BOOL 参数）
static NSArray<NSString *> *WFFoldSelectors(void) {
    return @[@"setFoldSession:", @"foldSession:", @"updateSessionFoldStatus:",
             @"setM_bIsFoldSession:", @"setSessionFold:flag:", @"markSessionAsFolded:"];
}

static NSArray<NSString *> *WFUserNameKeys(void) {
    return @[@"m_nsUserName", @"m_nsUsrName", @"m_nsFromUser", @"userName"];
}

static NSArray<NSString *> *WFContactKeys(void) {
    return @[@"m_contact", @"m_oContact", @"contact"];
}

static NSArray<NSString *> *WFSaveSelectors(void) {
    return @[@"UpdateSession:", @"updateSession:", @"saveSession:", @"ModifySession:", @"reloadSession"];
}

static NSArray<NSString *> *WFReloadSelectors(void) {
    return @[@"reloadData", @"reloadSessionList", @"refreshSessionList",
             @"updateSessionList", @"reloadTableView"];
}

#pragma mark - 日志

#define WFLOG(fmt, ...) WFLogMessage(([NSString stringWithFormat:(fmt), ##__VA_ARGS__]))

static void WFLogMessage(NSString *msg) {
    if (!msg) return;
    NSLog(@"[WeChatFold] %@", msg);
    @try {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!dir) return;
        NSString *path = [dir stringByAppendingPathComponent:@"WeChatFold.log"];
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

#pragma mark - 会话定位

static id WFGetService(Class serviceClass) {
    id center = WFCallNoArg(NSClassFromString(@"MMServiceCenter"), @"defaultCenter");
    if (!center) { WFLOG(@"MMServiceCenter 未找到"); return nil; }
    if (!serviceClass) return nil;
    BOOL ok = NO;
    id svc = WFCallWithObject(center, @"getService:", serviceClass, &ok);
    if (!ok) svc = WFCallWithObject(center, @"getService:", NSStringFromClass(serviceClass), &ok);
    if (!svc) WFLOG(@"getService:%@ 失败", NSStringFromClass(serviceClass));
    return svc;
}

// 服务中心候选类名
static NSArray<NSString *> *WFServiceCenterCandidates(void) {
    return @[@"MMServiceCenter", @"WCServiceCenter", @"MMServiceCenterMgr", @"ServiceCenter"];
}

// 会话管理器候选类名
static NSArray<NSString *> *WFSessionMgrCandidates(void) {
    return @[@"MMSessionMgr", @"SessionMgr", @"WCSessionMgr",
             @"MMSessionService", @"MMSessionManager", @"MMSessionMgrService",
             @"WCConversationMgr", @"ConversationMgr"];
}

static id WFGetSessionMgr(void) {
    WFLOG(@"---- 开始探测会话管理器 ----");
    for (NSString *centerName in WFServiceCenterCandidates()) {
        Class centerCls = NSClassFromString(centerName);
        if (!centerCls) continue;
        id center = WFCallNoArg(centerCls, @"defaultCenter");
        if (!center) {
            WFLOG(@"服务中心 %@ : 取不到 defaultCenter", centerName);
            continue;
        }
        WFLOG(@"服务中心命中: %@", centerName);
        for (NSString *mgrName in WFSessionMgrCandidates()) {
            Class mgrCls = NSClassFromString(mgrName);
            if (!mgrCls) continue;
            BOOL ok = NO;
            id svc = WFCallWithObject(center, @"getService:", mgrCls, &ok);
            if (svc) {
                WFLOG(@"会话管理器命中: %@ (via %@)", mgrName, centerName);
                return svc;
            }
        }
    }
    WFLOG(@"会话管理器：全部候选均未命中");
    return nil;
}

// 暴力枚举：把微信里所有跟会话/群聊/折叠相关的类、方法、ivar 全部写进日志
static void WFEnumerateRelatedClasses(void) {
    WFLOG(@"==== 开始枚举相关类 ====");
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { WFLOG(@"无法获取类列表"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned)n);
    n = objc_getClassList(classes, n);
    int hit = 0;
    for (int i = 0; i < n; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        NSString *clsName = [NSString stringWithUTF8String:cname];
        if (!([clsName containsString:@"Session"] ||
              [clsName containsString:@"Chatroom"] ||
              [clsName containsString:@"ChatRoom"] ||
              [clsName containsString:@"Fold"] ||
              [clsName containsString:@"Conversation"])) continue;

        hit++;
        if (hit > 120) { WFLOG(@"(类过多，截断)"); break; }
        WFLOG(@"[类] %@", clsName);

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(classes[i], &mc);
        int mShown = 0;
        for (unsigned int j = 0; j < mc && mShown < 25; j++) {
            NSString *mn = NSStringFromSelector(method_getName(ms[j]));
            if ([mn containsString:@"Session"] || [mn containsString:@"Fold"] ||
                [mn containsString:@"All"]   || [mn containsString:@"List"] ||
                [mn containsString:@"Chatroom"] || [mn containsString:@"ChatRoom"]) {
                WFLOG(@"    -%@", mn);
                mShown++;
            }
        }
        free(ms);

        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(classes[i], &ic);
        int iShown = 0;
        for (unsigned int j = 0; j < ic && iShown < 15; j++) {
            const char *iname = ivar_getName(ivs[j]);
            if (!iname) continue;
            NSString *iv = [NSString stringWithUTF8String:iname];
            if ([iv containsString:@"ession"] || [iv containsString:@"old"] || [iv containsString:@"rrSession"]) {
                WFLOG(@"    ivar %@ (%s)", iv, ivar_getTypeEncoding(ivs[j]) ?: "?");
                iShown++;
            }
        }
        free(ivs);
    }
    free(classes);
    WFLOG(@"==== 枚举结束，命中 %d 个类 ====", hit);
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

static NSString *WFSessionUserName(id session) {
    for (NSString *key in WFUserNameKeys()) {
        id v = WFValueForKey(session, key);
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
    }
    return nil;
}

static BOOL WFIsChatroomSession(id session) {
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
        id flag = WFValueForKey(contact, @"m_bIsChatroom");
        if ([flag respondsToSelector:@selector(boolValue)] && [flag boolValue]) return YES;
    }
    return NO;
}

#pragma mark - 诊断 dump

static void WFDumpObject(id obj, NSString *tag) {
    if (!obj) { WFLOG(@"dump %@ -> nil", tag); return; }
    Class cls = [obj class];
    WFLOG(@"==== dump %@ : %@ ====", tag, NSStringFromClass(cls));

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        WFLOG(@"  ivar %s (%s)", ivar_getName(ivars[i]) ?: "?", ivar_getTypeEncoding(ivars[i]) ?: "?");
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
    for (unsigned int i = 0; i < mCount; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name rangeOfString:@"old"].location != NSNotFound ||
            [name rangeOfString:@"Fold"].location != NSNotFound ||
            [name rangeOfString:@"Session"].location != NSNotFound ||
            [name rangeOfString:@"Chatroom"].location != NSNotFound) {
            WFLOG(@"  method %@", name);
        }
    }
    free(methods);
    WFLOG(@"==== dump %@ 结束 ====", tag);
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

static NSInteger WFRunFold(BOOL fold) {
    id mgr = WFGetSessionMgr();
    if (!mgr) return -1;
    NSArray *sessions = WFAllSessions(mgr);
    if (!sessions) {
        WFDumpObject(mgr, @"MMSessionMgr");
        return -1;
    }

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
            for (NSString *saveSel in WFSaveSelectors()) {
                if (WFCallWithObject(mgr, saveSel, session, NULL)) break;
            }
        } else if (!dumped) {
            WFDumpObject(session, @"Session");
            dumped = YES;
        }
    }

    gWFChatrooms = total;
    gWFSuccess = success;
    WFLOG(@"%@ 结果：成功 %ld / 群聊 %ld / 会话总数 %ld",
          fold ? @"折叠" : @"展开", (long)success, (long)total, (long)sessions.count);

    for (NSString *selName in WFReloadSelectors()) {
        if (WFCallNoArg(mgr, selName)) { WFLOG(@"刷新命中 -%@", selName); break; }
    }
    return success;
}

#pragma mark - UI 辅助

static UIWindow *WFKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
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

#pragma mark - Hook 记录

static NSMutableString *gWFHookReport = nil;

static void WFNoteHook(NSString *clsName, NSString *role, BOOL ok) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWFHookReport = [NSMutableString string]; });
    [gWFHookReport appendFormat:@"%@ %@ (%@)\n", ok ? @"[OK]" : @"[--]", clsName, role];
}

#pragma mark - WFManager

@interface WFManager : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, weak) UIView *hostView;
@property (nonatomic, weak) UIViewController *lastVC;
@property (nonatomic, weak) UIViewController *lastSettingVC;
+ (instancetype)shared;
- (void)attachTo:(UIView *)view;
- (void)injectSettingEntry:(UIViewController *)vc;
- (void)showMenuFrom:(UIViewController *)vc;
- (void)showBootAlertOn:(UIViewController *)vc;
- (void)showLogFrom:(UIViewController *)vc;
- (void)copyLogToPasteboard;
- (void)closeLog;
@end

@implementation WFManager

+ (instancetype)shared {
    static WFManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[WFManager alloc] init]; });
    return m;
}

#pragma mark 悬浮按钮

- (void)attachTo:(UIView *)view {
    if (!view || self.hostView == view) return;
    self.hostView = view;
    if (self.button) [self.button removeFromSuperview];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(view.bounds.size.width - 74, view.bounds.size.height - 220, 58, 58);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    btn.layer.cornerRadius = 29;
    btn.layer.masksToBounds = YES;
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    btn.titleLabel.numberOfLines = 2;
    [btn setTitle:@"群聊\n折叠" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(onButtonTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];
    [view addSubview:btn];
    self.button = btn;
    WFLOG(@"悬浮按钮已添加");
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (!self.hostView) return;
    CGPoint p = [g translationInView:self.hostView];
    g.view.center = CGPointMake(g.view.center.x + p.x, g.view.center.y + p.y);
    [g setTranslation:CGPointZero inView:self.hostView];
}

- (void)onButtonTap {
    UIViewController *vc = [self presenterVC];
    if (!vc) { WFLOG(@"找不到承载 VC"); return; }
    [self showMenuFrom:vc];
}

- (UIViewController *)presenterVC {
    if (self.lastVC) return self.lastVC;
    UIResponder *r = self.hostView;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = [r nextResponder];
    }
    return WFKeyWindow().rootViewController;
}

#pragma mark 设置页入口

- (void)injectSettingEntry:(UIViewController *)vc {
    @try {
        UITableView *tv = WFFindTableViewIn(vc.view);
        if (!tv) return;
        if (tv.tableFooterView && tv.tableFooterView.tag == 987654) return;

        CGFloat w = tv.bounds.size.width > 0 ? tv.bounds.size.width : 320;
        UIView *entry = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
        entry.tag = 987654;
        entry.backgroundColor = [UIColor whiteColor];

        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0.5)];
        line.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.3];
        [entry addSubview:line];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, w - 60, 40)];
        lb.text = @"群聊批量折叠";
        lb.font = [UIFont systemFontOfSize:16];
        lb.textColor = [UIColor blackColor];
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
    UIViewController *vc = self.lastSettingVC ?: [self presenterVC];
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
    UIAlertAction *dump = [UIAlertAction actionWithTitle:@"输出诊断信息"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
        WFLOG(@"==== 用户触发诊断 ====");
        WFEnumerateRelatedClasses();
        id mgr = WFGetSessionMgr();
        WFDumpObject(mgr, @"SessionMgr");
        NSArray *s = WFAllSessions(mgr);
        if (s.count) WFDumpObject(s.firstObject, @"Session[0]");
        [self alert:@"诊断已写入日志。点「查看日志」→「复制全部」，粘贴发给我。" from:vc];
    }];
    UIAlertAction *viewLog = [UIAlertAction actionWithTitle:@"查看日志"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }];
    UIAlertAction *hide = [UIAlertAction actionWithTitle:@"隐藏悬浮按钮"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) { self.button.hidden = YES; }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [ac addAction:fold]; [ac addAction:unfold]; [ac addAction:dump];
    [ac addAction:viewLog]; [ac addAction:hide]; [ac addAction:cancel];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.button ?: vc.view;
        ac.popoverPresentationController.sourceRect = self.button ? self.button.bounds : CGRectMake(0, 0, 1, 1);
    }
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark 执行

- (void)run:(BOOL)fold from:(UIViewController *)vc {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger n = WFRunFold(fold);
        NSInteger totalSessions = gWFTotalSessions;
        NSInteger chatrooms = gWFChatrooms;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *msg;
            if (n < 0) {
                msg = @"失败：没找到会话列表。\n\nMMSessionMgr 或它的方法名对不上你的微信版本。\n\n点「查看日志」把日志发给我。";
            } else if (totalSessions == 0) {
                msg = @"失败：会话列表是空的。\n\n拿到了管理器，但取列表的方法名不对。\n\n点「查看日志」把日志发给我。";
            } else if (chatrooms == 0) {
                msg = [NSString stringWithFormat:@"拿到了 %ld 条会话，但一条群聊都没认出来。\n\n群聊判断条件没匹配上。\n\n点「查看日志」把日志发给我。", (long)totalSessions];
            } else if (n == 0) {
                msg = [NSString stringWithFormat:@"认出 %ld 个群聊，但一个都没折叠成功。\n\n折叠用的属性/方法名没命中。\n\n日志里已 dump 出真实属性名，点「查看日志」发给我。", (long)chatrooms];
            } else {
                msg = [NSString stringWithFormat:@"成功 %ld 个，共识别 %ld 个群聊（会话总数 %ld）。", (long)n, (long)chatrooms, (long)totalSessions];
            }
            [self alert:msg from:vc];
        });
    });
}

#pragma mark 启动自检弹窗

- (NSString *)statusReport {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"插件已加载。状态如下：\n\n"];
    [s appendFormat:@"%@", gWFHookReport ?: @"(hook 未执行)\n"];
    [s appendString:@"\n"];
    [s appendFormat:@"MMServiceCenter 类：%@\n", NSClassFromString(@"MMServiceCenter") ? @"存在" : @"不存在"];
    [s appendFormat:@"MMSessionMgr 类：%@\n", NSClassFromString(@"MMSessionMgr") ? @"存在" : @"不存在"];
    id mgr = WFGetSessionMgr();
    [s appendFormat:@"会话管理器实例：%@\n", mgr ? @"已获取" : @"未获取"];
    if (mgr) {
        NSArray *ss = WFAllSessions(mgr);
        [s appendFormat:@"会话数量：%@\n", ss ? [NSString stringWithFormat:@"%lu", (unsigned long)ss.count] : @"取不到列表"];
    }
    return s;
}

- (void)showBootAlertOn:(UIViewController *)vc {
    if (!vc) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WFBootAlertDisabled"]) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"WeChatFold"
                                                               message:[self statusReport]
                                                        preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"折叠全部群聊"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self run:YES from:vc]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"展开全部群聊"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self run:NO from:vc]; }]];
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

- (NSString *)logFilePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return dir ? [dir stringByAppendingPathComponent:@"WeChatFold.log"] : nil;
}

- (void)showLogFrom:(UIViewController *)vc {
    NSString *log = [NSString stringWithContentsOfFile:[self logFilePath]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    if (!log || log.length == 0) {
        log = @"(暂无日志)\n\n先执行一次折叠或诊断，再回来看这里。";
    }
    if (log.length > 30000) log = [log substringFromIndex:log.length - 30000];

    UIViewController *logVC = [[UIViewController alloc] init];
    logVC.title = @"WeChatFold 日志";
    logVC.view.backgroundColor = [UIColor whiteColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:logVC.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.text = log;
    tv.font = [UIFont systemFontOfSize:11];
    tv.editable = NO;
    tv.backgroundColor = [UIColor whiteColor];
    tv.textColor = [UIColor blackColor];
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
    NSString *log = [NSString stringWithContentsOfFile:[self logFilePath]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
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

static void WFHookViewDidAppear(Class cls, BOOL isSetting) {
    if (!cls) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWFHooked = [NSMutableSet set]; });

    NSString *clsName = NSStringFromClass(cls);
    if ([gWFHooked containsObject:clsName]) return;

    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WFNoteHook(clsName, isSetting ? @"设置页" : @"主界面", NO);
        WFLOG(@"%@ 没有 viewDidAppear:", clsName);
        return;
    }
    [gWFHooked addObject:clsName];

    IMP orig = method_getImplementation(m);
    IMP newIMP = imp_implementationWithBlock(^(id _self, BOOL animated) {
        if (orig) ((void (*)(id, SEL, BOOL))orig)(_self, sel, animated);
        @try {
            if ([_self isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)_self;
                [[WFManager shared] setLastVC:vc];
                if (isSetting) {
                    [[WFManager shared] injectSettingEntry:vc];
                } else if ([vc respondsToSelector:@selector(view)]) {
                    [[WFManager shared] attachTo:vc.view];
                }
            }
        } @catch (NSException *e) {
            WFLOG(@"hook 回调异常：%@", e.reason);
        }
    });
    method_setImplementation(m, newIMP);
    WFNoteHook(clsName, isSetting ? @"设置页" : @"主界面", YES);
    WFLOG(@"已 hook %@", clsName);
}

static void WFInstallHooks(void) {
    BOOL anyMain = NO, anySetting = NO;
    for (NSString *name in WFMainFrameCandidates()) {
        Class c = NSClassFromString(name);
        if (c) { WFHookViewDidAppear(c, NO); anyMain = YES; }
    }
    for (NSString *name in WFSettingCandidates()) {
        Class c = NSClassFromString(name);
        if (c) { WFHookViewDidAppear(c, YES); anySetting = YES; }
    }
    if (!anyMain) WFLOG(@"主界面候选类名一个都没命中");
    if (!anySetting) WFLOG(@"设置页候选类名一个都没命中");
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
    [[WFManager shared] showBootAlertOn:root];
}

#pragma mark - 入口

__attribute__((constructor))
static void WFEntry(void) {
    WFLOG(@"=== WeChatFold dylib 已加载 (pid=%d) ===", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { WFInstallHooks(); }
        @catch (NSException *e) { WFLOG(@"安装 hook 失败：%@", e.reason); }
        WFTryBootAlert(0);
    });
}
