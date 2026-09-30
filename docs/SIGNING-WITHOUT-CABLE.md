# 不用数据线装进 iPhone —— 签名方案全对比

前置：ipa 已在 `builds` 分支，手机 Safari 直接打开即可下载（不用登录 GitHub）：

```
https://raw.githubusercontent.com/<你的用户名>/jev-chat-jarvis-ios/builds/JevJarvis-unsigned.ipa
```

下载后在「文件」App 里能找到，再喂给下面的任意一个签名工具。

---

## 先搞清两件事，否则白折腾

### 1️⃣ 你的 iOS 版本决定 TrollStore 能不能用

| iOS 版本 | TrollStore |
|---|---|
| 14.0 – 16.6.1 / 16.7 RC / 17.0 | ✅ 可用（永久签名，最省事） |
| 17.0.1 及以上（含 18 / 26） | ❌ 漏洞已被苹果永久修补，无解 |

设置 → 通用 → 关于本机 → 软件版本，先看一眼。

### 2️⃣ App Group 是成败关键

这个键盘靠 App Group `group.com.<你的用户名>.jevjarvis` 从宿主 App 读 API Key。
**签名时如果 App Group 权限被剥掉 → App 装得上、但键盘永远拿不到 Key，等于废包。**

一个好消息：这个 App 的 entitlements 非常干净，只有 **1 个 App Group**，没有推送 / VPN / iCloud 这些免费账号拿不到的权限。
苹果对**免费个人账号**的限制是「最多 3 个 App Group」—— 我们的 1 个在额度内，**所以免费 Apple ID 是有戏的**，不需要为了 App Group 去买 $99 账号。

但这条依赖签名工具老实写入 entitlements，所以装好后**第一件事就去做「验证」那一节**。

---

## 六条路线对比

| 路线 | 需要数据线 | 之后的续签 | 花钱 | App Group | 稳定性 |
|---|---|---|---|---|---|
| **A. SideStore** | 一次（仅首次） | **全自动，永不用电脑** | 免费 | ✅ | 高 |
| **B. Feather + 免费 Apple ID** | 否 | 每 7 天手机上点一下 | 免费 | ✅ | 高 |
| **C. 付费开发者账号 + Feather** | 否 | **一年一次** | $99/年 | ✅ | 最高 |
| **D. TrollStore** | 否 | 永不续签 | 免费 | ✅ | 最高（吃版本） |
| **E. TestFlight（找作者要名额）** | 否 | 90 天 | 免费 | ✅ | 最高 |
| **F. 企业共享证书 / ESign 自带证书** | 否 | 随时掉签 | 免费~几十元 | ❌ 大概率拿不到 | 最差 |

> 「必须插一次线」的只有 A。其余都能做到零插线，但各有代价。

---

## A. SideStore —— 一次插线，换永久免线（推荐）

SideStore 是 AltStore 的分支，专门解决「每 7 天要插线重签」这个痛点。

**为什么推荐**：之后连续签都在手机上自动完成，再也不用碰电脑。相比你现在用 Sideloadly 每 7 天插一次线，是质的差别。

**代价**：首次安装要插一次线（SideStore 要一个 pairing file，生成它必须连一次 USB）。

步骤：

1. Windows 装 **AltServer**（[altstore.io](https://altstore.io)，会顺带装 Apple 的设备驱动）和 **iTunes**（非 Microsoft Store 版）
2. iPhone 插线，信任电脑
3. 用 AltServer 把 **SideStore.ipa** 装到手机（SideStore 官网下载）
4. 同一个 AltServer 里生成 **pairing file**，传到手机
5. 手机装 **StosVPN**（App Store 里就有），把 pairing file 导入 SideStore
6. 搞定 —— 之后导入我们的 ipa、签名、续签，全在手机上完成

> 内网进阶方案：如果你软路由上能写 nftables 规则，可以彻底免掉 StosVPN（见 [lantian.pub 的教程](https://lantian.pub/article/modify-computer/sidestore-without-stosvpn-across-lan.lantian/)）。你的 OpenWrt 软路由正好合适。

---

## B. Feather + 自己的免费 Apple ID —— 零插线，全免费

Feather 是个开源的**设备端**签名器，能在 iPhone 上直接用你的 Apple ID 生成证书、签名、安装，全程不碰电脑。

**鸡生蛋问题**：Feather 自己也得先装进手机。零插线的做法：
- 用 **ESign / 全能签 / GBox** 这类设备端工具先装 Feather（它们自带共享证书，扫码或描述文件安装，不用电脑）
- 或者如果你有 TrollStore，直接 TrollStore 装 Feather

**装好 Feather 后**：

1. Feather → Settings → Certificates → Add Account
   - 填 Apple ID，**2FA 账号要先生成 App 专用密码**（appleid.apple.com → 登录与安全 → App 专用密码）
2. Feather 自动生成签名证书（免费账号：7 天有效、最多 3 个 App）
3. 把下载的 ipa 导入 Feather → Sign
   - ⚠️ **关掉 Bundle ID 随机化**（设置里的 PPQCheck 保护），否则 Bundle ID 被加随机后缀，App Group 对不上
4. Install → 设置 → 通用 → VPN与设备管理 → 信任
5. 7 天后 Feather 里点一下重新签名即可，**不用电脑**

---

## C. 付费开发者账号 —— 零插线，最省心

Apple Developer Program，$99/年（个人）。收益是质变：

- 证书 **1 年**有效，不是 7 天
- **不限 App 数量**（免费账号只有 3 个）
- 可以用 Feather 直接在手机上签，也可以用 **AltStore**（此时不需要电脑了）
- 能自己签 Ad-Hoc 描述文件，配合 OTA 链接直接浏览器安装

如果你打算长期用、或者身边还有别人要用，这是唯一「一次投入、彻底清静」的选项。

---

## D. TrollStore —— 零插线、永久有效（先看版本）

如果上面第 1 条你的版本在支持范围内：

- 用 **TrollInstallerX**（iOS 14.0–16.6.1，纯手机操作，不用电脑）装 TrollStore
- 之后把 ipa 喂给 TrollStore 直接装
- **永久签名、不续签、不掉签**，而且 **App Group 完整保留**

这是所有方案里体验最好的，可惜苹果把漏洞修了，只有老版本能吃到。

---

## E. TestFlight —— 一条消息换 90 天

作者正在准备上架（仓库里有完整的中英文 App Store 截图和提审脚本）。去 README 里找公众号私信作者要一个 TestFlight 名额：

- 手机上装 TestFlight → 点邀请链接 → 安装
- **90 天有效**、不用签名、不用电脑、App Group 完整
- 代价只是「看作者给不给」

---

## F. 企业共享证书 / ESign 自带证书 —— 不推荐

各种「在线签名」「超级签名」网站、ESign 自带的免费证书，本质是**别人家的企业证书**在给你签名。

- 掉签是常态（几小时到几天），一掉签 App 直接打不开
- **App Group 基本申请不下来** —— 企业证书不会为你注册自定义 App Group，键盘会读不到 Key
- 你的 Apple ID 密码可能被第三方服务器留存

除非只是「先试试界面长什么样」，否则不建议走这条。

---

## 装好后的验证（必做）

这一步决定整个方案是否真的成立。

1. 打开 **Jev Jarvis App** → 模型页 → 填两把 Key → 点「测试连接」
   - 生成层选 `DeepSeek 官方`，Key 用 `sk-9761...`
   - 判断层选 `OpenRouter 网关`，Key 用 `sk-or-v1-21ff...`
2. 去任意输入框调出 **Jev 键盘** → 必须打开「允许完全访问」
3. 复制一段聊天文字 → 键盘上点「分析剪贴板」

| 结果 | 说明 |
|---|---|
| 出候选回复 | ✅ 全通了，App Group 保住了 |
| 没反应 / 提示未配置 | ❌ App Group 被剥掉 → 走下面的兜底 |

**兜底方案**：如果确认是 App Group 没保住，把 `build-info.txt` 发出来，我可以改成「键盘内直接填 Key」，彻底绕开 App Group 共享（代价是两处各填一次）。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| Safari 打不开 builds 链接 | 分支还没生成（构建失败） | 去 Actions 页看 latest run；读 `ci-log` 分支的 build.log |
| 装完打开闪退 | 没信任证书 | 设置 → 通用 → VPN与设备管理 → 信任 |
| 提示「无法验证 App」 | 同上，或证书已被吊销 | 重新签名安装 |
| 键盘列表里找不到 Jev 键盘 | 键盘扩展没装进去 | 确认 ipa 里的 `PlugIns/JevKeyboard.appex` 存在（build-info 有记录） |
| 键盘能出现但没数据 | App Group 没保住 | 见上面「验证」的兜底方案 |
| 7 天后 App 打不开 | 免费证书过期 | 走对应工具的重新签名（Feather 点一下 / SideStore 自动 / TrollStore 不会发生） |
