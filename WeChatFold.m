//
//  WeChatFold.m
//  微信群聊批量折叠 —— TrollStore / 巨魔注入版
//
//  设计要点：
//  1. 零依赖：不使用 CydiaSubstrate、不使用 Logos %hook。
//     巨魔(TrollStore)环境没有 Substrate 运行时，dylib 必须自包含。
//     这里用纯 Objective-C runtime (method_setImplementation / NSInvocation / KVC) 实现。
//  2. 弱耦合：微信内部类与属性名随版本变化，采用「候选名探测」策略，
//     运行时逐个试探，命中即用，并把命中的真实 API 名写进日志。
//  3. 可诊断：所有探测结果同时写 NSLog 和 App 沙盒 Documents/WeChatFold.log，
//     巨魔环境下可用 TrollStore 的文件访问 / Filza 取出查看。
//
//  仅供个人自用与学习研究，请勿用于任何违反微信用户协议或法律法规的用途。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 可配置区：如你的微信版本对不上，改这里

static NSString * const kWFMainFrameClass  = @"MainFrameViewController";
static NSString * const kWFSessionMgrClass = @"MMSessionMgr";
static NSString * const kWFContactMgrClass = @"CContactMgr";

// 拿到「全部会话列表」的候选方法名
static NSArray<NSString *> *WFSessionListSelectors(void) {
    return @[@"getAllSessions",
             @"GetAllSession",
             @"getSessionList",
             @"getAllSessionInfo",
             @"getSessions"];
}

// 会话列表的候选属性名（当方法名都命中不了时，退化为 KVC 读取）
static NSArray<NSString *> *WFSessionListKeys(void) {
    return @[@"m_arrSession", @"m_arrSessionInfo", @"m_sessionList", @"arrSession"];
}

// 「是否折叠」的候选属性名（KVC 写入）
static NSArray<NSString *> *WFFoldKeys(void) {
    return @[@"m_bIsFoldSession",
             @"m_bFolded",
             @"m_bIsFold",
             @"m_bShowInFoldList",
             @"m_uiFoldSessionFlag",
             @"m_bFoldSession",
             @"m_bInFoldSessionList"];
}

// 「设置折叠」的候选方法名（带一个 BOOL 参数）
static NSArray<NSString *> *WFFoldSelectors(void) {
    return @[@"setFoldSession:",
             @"foldSession:",
             @"updateSessionFoldStatus:",
             @"setM_bIsFoldSession:",
             @"setSessionFold:flag:",
             @"markSessionAsFolded:"];
}

// 会话对象里「用户名」的候选属性名
static NSArray<NSString *> *WFUserNameKeys(void) {
    return @[@"m_nsUserName", @"m_nsUsrName", @"m_nsFromUser", @"userName"];
}

// 会话对象里「联系人对象」的候选属性名
static NSArray<NSString *> *WFContactKeys(void) {
    return @[@"m_contact", @"m_oContact", @"contact"];
}

// 保存会话变更的候选方法名
static NSArray<NSString *> *WFSaveSelectors(void) {
    return @[@"UpdateSession:", @"updateSession:", @"saveSession:", @"ModifySession:", @"reloadSession"];
}

// 刷新会话列表 UI 的候选方法名
static NSArray<NSString *> *WFReloadSelectors(void) {
    return @[@"reloadData",
             @"reloadSessionList",
             @"refreshSessionList",
             @"updateSessionList",
             @"reloadTableView"];
}

#pragma mark - 日志：同时输出 NSLog 与沙盒文件

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

#pragma mark - 运行时小工具

static id WFValueForKey(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static BOOL WFSetBoolForKey(id obj, NSString *key, BOOL value) {
    if (!obj || !key) return NO;
    @try {
        [obj setValue:@(value) forKey:key];
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// 无参调用，返回对象
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

// 带一个对象参数调用，ok 表示是否成功发起调用
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

// 带一个 BOOL 参数调用，返回是否成功发起调用
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

#pragma mark - 业务：定位会话管理器 / 会话列表

static id WFGetService(Class serviceClass) {
    id center = WFCallNoArg(NSClassFromString(@"MMServiceCenter"), @"defaultCenter");
    if (!center) { WFLOG(@"MMServiceCenter not found"); return nil; }
    if (!serviceClass) { WFLOG(@"service class nil"); return nil; }
    BOOL ok = NO;
    id svc = WFCallWithObject(center, @"getService:", serviceClass, &ok);
    if (!ok) {
        svc = WFCallWithObject(center, @"getService:", NSStringFromClass(serviceClass), &ok);
    }
    if (!svc) WFLOG(@"getService:%@ failed", NSStringFromClass(serviceClass));
    return svc;
}

static NSArray *WFAllSessions(id mgr) {
    for (NSString *selName in WFSessionListSelectors()) {
        id r = WFCallNoArg(mgr, selName);
        if ([r isKindOfClass:[NSArray class]]) {
            WFLOG(@"session list hit selector: -%@ (%lu items)", selName, (unsigned long)[r count]);
            return r;
        }
    }
    for (NSString *key in WFSessionListKeys()) {
        id r = WFValueForKey(mgr, key);
        if ([r isKindOfClass:[NSArray class]]) {
            WFLOG(@"session list hit key: %@ (%lu items)", key, (unsigned long)[r count]);
            return r;
        }
    }
    WFLOG(@"!! 未能定位会话列表，请查看下方 dump 信息");
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

#pragma mark - 诊断：dump 一个对象的 ivar / property / method

static void WFDumpObject(id obj, NSString *tag) {
    if (!obj) { WFLOG(@"dump %@ -> nil", tag); return; }
    Class cls = [obj class];
    WFLOG(@"==== dump %@ : %@ ====", tag, NSStringFromClass(cls));

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *n = ivar_getName(ivars[i]);
        const char *t = ivar_getTypeEncoding(ivars[i]);
        WFLOG(@"  ivar %s  (%s)", n ?: "?", t ?: "?");
    }
    free(ivars);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        WFLOG(@"  @property %s", property_getName(props[i]));
    }
    free(props);

    unsigned int mCount = 0;
    Method *methods = class_copyMethodList(cls, &mCount);
    for (unsigned int i = 0; i < mCount; i++) {
        SEL s = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(s);
        if ([name rangeOfString:@"old"].location != NSNotFound ||
            [name rangeOfString:@"Fold"].location != NSNotFound ||
            [name rangeOfString:@"Session"].location != NSNotFound) {
            WFLOG(@"  method %@", name);
        }
    }
    free(methods);
    WFLOG(@"==== dump %@ end ====", tag);
}

#pragma mark - 业务：执行折叠 / 展开

static NSInteger gWFTotalSessions = 0;
static NSInteger gWFChatrooms     = 0;
static NSInteger gWFSuccess       = 0;

static BOOL WFApplyFoldToSession(id session, BOOL fold) {
    // 路线 A：KVC 直接写属性
    for (NSString *key in WFFoldKeys()) {
        if (WFSetBoolForKey(session, key, fold)) {
            WFLOG(@"fold via KVC key: %@ = %@", key, fold ? @"YES" : @"NO");
            return YES;
        }
    }
    // 路线 B：调 setter 方法
    for (NSString *selName in WFFoldSelectors()) {
        if (WFCallWithBool(session, selName, fold)) {
            WFLOG(@"fold via selector: -%@(%@)", selName, fold ? @"YES" : @"NO");
            return YES;
        }
    }
    // 路线 C：写到关联的联系人对象上
    for (NSString *ckey in WFContactKeys()) {
        id contact = WFValueForKey(session, ckey);
        if (!contact) continue;
        for (NSString *key in WFFoldKeys()) {
            if (WFSetBoolForKey(contact, key, fold)) {
                WFLOG(@"fold via contact.%@ = %@", key, fold ? @"YES" : @"NO");
                return YES;
            }
        }
    }
    return NO;
}

static NSInteger WFRunFold(BOOL fold) {
    id mgr = WFGetService(NSClassFromString(kWFSessionMgrClass));
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
            // 尝试落库
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
    WFLOG(@"%@ 群聊：成功 %ld / 群聊总数 %ld / 会话总数 %ld",
          fold ? @"折叠" : @"展开", (long)success, (long)total, (long)sessions.count);

    // 刷新 UI
    for (NSString *selName in WFReloadSelectors()) {
        if (WFCallNoArg(mgr, selName)) {
            WFLOG(@"refresh via -%@", selName);
            break;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"WeChatFoldReloadSessions"
                                                            object:nil
                                                          userInfo:@{@"fold": @(fold)}];
    });
    return success;
}

#pragma mark - UI：悬浮按钮 + 菜单

@interface WFManager : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, weak) UIView *hostView;
+ (instancetype)shared;
- (void)attachTo:(UIView *)view;
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

- (void)attachTo:(UIView *)view {
    if (!view || self.hostView == view) return;
    self.hostView = view;
    if (self.button) [self.button removeFromSuperview];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(view.bounds.size.width - 74,
                           view.bounds.size.height - 220,
                           58, 58);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    btn.layer.cornerRadius = 29;
    btn.layer.masksToBounds = YES;
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    btn.titleLabel.numberOfLines = 2;
    [btn setTitle:@"群聊\n折叠" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

    // 支持拖动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];

    [view addSubview:btn];
    self.button = btn;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (!self.hostView) return;
    CGPoint p = [g translationInView:self.hostView];
    g.view.center = CGPointMake(g.view.center.x + p.x, g.view.center.y + p.y);
    [g setTranslation:CGPointZero inView:self.hostView];
}

- (void)onTap {
    UIViewController *vc = [self currentVCFromView:self.hostView];
    if (!vc) { WFLOG(@"can not find presenter VC"); return; }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"微信群聊折叠"
                                                               message:@"选择操作（日志写入 Documents/WeChatFold.log）"
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
        id mgr = WFGetService(NSClassFromString(kWFSessionMgrClass));
        WFDumpObject(mgr, @"MMSessionMgr");
        NSArray *s = WFAllSessions(mgr);
        if (s.count) WFDumpObject(s.firstObject, @"Session[0]");
        [self alert:@"已写入日志" from:vc];
    }];
    UIAlertAction *viewLog = [UIAlertAction actionWithTitle:@"查看日志"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [self showLogFrom:vc]; }];
    UIAlertAction *hide = [UIAlertAction actionWithTitle:@"隐藏按钮（本次运行）"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) { self.button.hidden = YES; }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [ac addAction:fold]; [ac addAction:unfold]; [ac addAction:dump];
    [ac addAction:viewLog]; [ac addAction:hide]; [ac addAction:cancel];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.button;
        ac.popoverPresentationController.sourceRect = self.button.bounds;
    }
    [vc presentViewController:ac animated:YES completion:nil];
}

- (void)run:(BOOL)fold from:(UIViewController *)vc {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger n = WFRunFold(fold);
        NSInteger totalSessions = gWFTotalSessions;
        NSInteger chatrooms = gWFChatrooms;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *msg;
            if (n < 0) {
                msg = @"失败：没找到会话列表。\n\n说明 MMSessionMgr 这个类或它的方法名对不上你的微信版本。\n\n点菜单里的「查看日志」，把日志发给我。";
            } else if (totalSessions == 0) {
                msg = @"失败：会话列表是空的。\n\n说明拿到了管理器但列表方法名不对。\n\n点「查看日志」把日志发给我。";
            } else if (chatrooms == 0) {
                msg = [NSString stringWithFormat:@"拿到了 %ld 条会话，但一条群聊都没认出来。\n\n说明群聊判断条件（@chatroom 后缀）没匹配上。\n\n点「查看日志」把日志发给我。", (long)totalSessions];
            } else if (n == 0) {
                msg = [NSString stringWithFormat:@"认出 %ld 个群聊，但一个都没折叠成功。\n\n说明「折叠」相关的属性/方法名没命中。\n\n点「查看日志」，日志里会有 dump 出的真实属性名，发给我。", (long)chatrooms];
            } else {
                msg = [NSString stringWithFormat:@"成功 %ld 个，共识别 %ld 个群聊（会话总数 %ld）。", (long)n, (long)chatrooms, (long)totalSessions];
            }
            [self alert:msg from:vc];
        });
    });
}

- (NSString *)logFilePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return dir ? [dir stringByAppendingPathComponent:@"WeChatFold.log"] : nil;
}

- (void)showLogFrom:(UIViewController *)vc {
    NSString *log = [NSString stringWithContentsOfFile:[self logFilePath]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    if (!log || log.length == 0) {
        log = @"(暂无日志)\n\n先点「输出诊断信息」或执行一次折叠，再回来看这里。";
    }
    if (log.length > 30000) {
        log = [log substringFromIndex:log.length - 30000];
    }

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
    UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
    [root dismissViewControllerAnimated:YES completion:nil];
}

- (void)alert:(NSString *)msg from:(UIViewController *)vc {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"微信群聊折叠"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

- (UIViewController *)currentVCFromView:(UIView *)v {
    UIResponder *r = v;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = [r nextResponder];
    }
    return [UIApplication sharedApplication].keyWindow.rootViewController;
}

@end

#pragma mark - 注入入口：hook MainFrameViewController

static void WFInstallHooks(void) {
    Class cls = NSClassFromString(kWFMainFrameClass);
    if (!cls) { WFLOG(@"class %@ not found", kWFMainFrameClass); return; }

    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { WFLOG(@"%@ has no viewDidAppear:", kWFMainFrameClass); return; }

    __block IMP origIMP = method_getImplementation(m);
    IMP newIMP = imp_implementationWithBlock(^(id _self, BOOL animated) {
        if (origIMP) ((void (*)(id, SEL, BOOL))origIMP)(_self, sel, animated);
        @try {
            if ([_self respondsToSelector:@selector(view)]) {
                UIView *v = [(UIViewController *)_self view];
                if (v) [[WFManager shared] attachTo:v];
            }
        } @catch (NSException *e) { WFLOG(@"attach failed: %@", e.reason); }
    });
    method_setImplementation(m, newIMP);
    WFLOG(@"hook installed on %@", kWFMainFrameClass);
}

__attribute__((constructor))
static void WFEntry(void) {
    WFLOG(@"dylib loaded (pid=%d)", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { WFInstallHooks(); }
        @catch (NSException *e) { WFLOG(@"init failed: %@", e.reason); }
    });
}
