# WeChatFold —— 微信群聊批量折叠（巨魔 / TrollStore 注入版）

> 仅供个人自用与技术学习。修改第三方 App 运行行为**违反微信用户协议，存在封号风险**，请自行评估后再使用。

## 为什么不用 Logos / %hook

巨魔（TrollStore）**不是越狱**，设备上没有 Cydia Substrate / Substitute / ElleKit 注入底座。
传统的 `%hook` + `MSHookIvar` 写法在这里跑不起来。

本项目改为：
- **纯 Objective-C runtime**（`method_setImplementation` / `NSInvocation` / KVC）
- **零外部依赖**，编译产物就是一个自包含的 `WeChatFold.dylib`
- 任何注入方式（TrollFools / optool 手动注入 / Sideloadly）都能用

## 目录说明

```
WeChatFold.m              核心逻辑（配置区在文件顶部）
Makefile                  Theos 编译配置
control                   deb 打包元信息
.github/workflows/         Windows 用户用 GitHub Actions 云编译
```

## 一、编译（Windows 用户走这条路）

1. 把本目录 push 到一个 GitHub 仓库（**公开仓库免费**，私有仓库每月 2000 分钟也够用）
2. 打开仓库的 Actions 页，会看到 `Build WeChatFold`
3. 跑完后在 Artifacts 里下载：
   - `WeChatFold.dylib` ← **巨魔注入要用的是这个**
   - `WeChatFold.deb` ← 越狱环境才会用到

本地 Windows 上只负责写代码（VS Code 即可），编译交给 macOS runner。

## 二、准备微信 IPA（必须砸壳）

App Store 安装的微信是加壳加密的，**无法注入**，必须先解密：

- 越狱设备：`dumpdecrypted` / `Clutch` / `flexdecrypt` 砸壳后导出 IPA
- 非越狱：从其他渠道获取已砸壳 IPA（注意来源可信度）

验证是否已砸壳：解包 IPA，看 `Payload/WeChat.app/WeChat` 的 `cryptid`：

```bash
otool -l Payload/WeChat.app/WeChat | grep -A4 LC_ENCRYPTION_INFO
# cryptid = 0 表示已砸壳
```

## 三、注入 dylib

### 方式 A：TrollFools（最省事）
在巨魔设备上用 TrollFools 选择已砸壳的微信，注入 `WeChatFold.dylib`，它会生成一个新 IPA。

### 方式 B：手动（optool）
```bash
# 1. 解包
unzip WeChat.ipa -d app/
cp WeChatFold.dylib app/Payload/WeChat.app/

# 2. 写入 LC_LOAD_DYLIB
optool install -c weak -p "@executable_path/WeChatFold.dylib" \
  -t app/Payload/WeChat.app/WeChat

# 3. 重新签名（巨魔环境用 TrollStore 自带的 ldid 签名即可）
# 4. 打包
cd app && zip -qr ../WeChat-Folded.ipa Payload
```

## 四、安装

用 **TrollStore** 安装 `WeChat-Folded.ipa`，用永久签名方式装。

> 注意：这会替换你原来的微信。先备份聊天记录（微信 → 我 → 设置 → 聊天 → 聊天记录迁移与备份）。

## 五、使用

打开微信主界面（会话列表），右下角会出现一个半透明圆形按钮：

| 菜单项 | 作用 |
|---|---|
| 折叠全部群聊 | 批量折叠所有群聊 |
| 展开全部群聊 | 反向操作 |
| 输出诊断信息 | dump 真实类名/属性/方法到日志 |
| 隐藏按钮 | 本次运行内隐藏 |

按钮支持拖动。

## 六、如果点了没反应（大概率会发生）

微信内部 API 每个版本都可能变，代码里内置的候选名只是社区常见写法，不保证命中你的版本。
**按下面的流程锁定真实 API：**

1. 点「输出诊断信息」
2. 取日志：`Documents/WeChatFold.log`（在微信沙盒内）
   - 巨魔设备：用 TrollStore → 已安装 App → 文件系统访问，或 Filza
   - 有 Mac：Console.app 过滤 `WeChatFold`
3. 日志里会列出 `MMSessionMgr` 和 `Session[0]` 的全部 ivar / property / method
4. 找到折叠相关的真实名字，填回 `WeChatFold.m` 顶部的配置区：
   - `WFFoldKeys()` — 折叠属性名
   - `WFFoldSelectors()` — 折叠方法名
   - `WFSessionListSelectors()` — 会话列表方法名
5. 重新编译注入

日志里带 `hit` 关键字的行表示**已经命中生效**，那是最理想的情况。

## 七、常见问题

**Q：为什么不做成 Substrate tweak 直接丢进 Filza？**
巨魔环境没有 MobileSubstrate 运行时，`.deb` 装进去也不会被加载。必须用 dylib 注入 IPA 的方式。

**Q：会封号吗？**
有风险。微信会检测客户端完整性和异常行为。建议小号测试，不要在主号上长期挂。

**Q：iOS 版本支持？**
arm64 / arm64e 都已编译，iOS 14 ~ 17 理论上可用，实际取决于微信版本内部结构。

**Q：能不能开机自动折叠？**
可以，把 `WFEntry` 里的 `WFInstallHooks()` 后面直接调一次 `WFRunFold(YES)` 即可，但建议先手动验证逻辑正确。
