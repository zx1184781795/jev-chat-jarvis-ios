# 云端编译手册（Windows 无 Mac 版）

在 Windows 上编译出能装进 iPhone 的 Jev Jarvis 键盘。全程 0 成本：

- 编译在 **GitHub 的 macOS runner** 上跑（公开仓库免费）
- 产出**未签名 ipa**
- 回到 Windows 用 **Sideloadly** 用你自己的 Apple ID 签名安装

不需要 Mac、不需要 Apple 付费会员、不需要证书。

> 本文档与 `.github/workflows/build-ios-unsigned.yml` 一起新增。原作者仓库不受影响，你只是在自己的 fork 里加了个流水线。

---

## 0. 先准备两样东西

| 需要 | 说明 |
|---|---|
| **GitHub 账号** | 免费即可。没有就注册一个 |
| **Sideloadly** | 从 `sideloadly.io` 下载 Windows 版 |
| **iTunes（Apple 官网版）** | Sideloadly 靠它拿 USB 驱动。**务必从 apple.com 下载 exe 版，不要装 Microsoft Store 版**，否则 Sideloadly 找不到设备 |

另外：iPhone 用**数据线**连电脑（不要用 Wi-Fi 调试）。

---

## 1. Fork 仓库

打开 <https://github.com/jev-chat/jev-chat-jarvis-ios> → 右上角 **Fork** → **Create fork**。

得到 `https://github.com/<你的用户名>/jev-chat-jarvis-ios`。

> 仓库是 MIT 协议，README 明确写了「个人和公司都可以使用、修改、再分发，不需要付费或事先授权」，放心改。

## 2. 把流水线放进你的 fork

二选一。

### 方式 A：网页粘贴（不用装任何东西）

1. 在 fork 页面点 **Add file → Create new file**
2. 文件名填 `.github/workflows/build-ios-unsigned.yml`（**斜杠要照打**，GitHub 会自动建目录）
3. 把本仓库里 `.github/workflows/build-ios-unsigned.yml` 的内容整段粘进去
4. 底部 **Commit changes**

### 方式 B：命令行（本地已有 clone 时）

把 `<你的用户名>` 换掉：

```bash
cd /d/jev-chat-jarvis-ios
git remote add fork https://github.com/<你的用户名>/jev-chat-jarvis-ios.git
git add .github/workflows/build-ios-unsigned.yml docs/CLOUD-BUILD.md
git commit -m "ci: 云端编译未签名 ipa 的流水线（无 Mac 场景）"
git push fork master
```

> 推送时 Git 会弹出 GitHub 登录窗口，登一次即可。

## 3. 启用 Actions

Fork 出来的仓库 **Actions 默认是关的**：

1. 进 fork → **Actions** 标签
2. 会看到一条提示，点 **I understand my workflows, go ahead and enable them**
3. 左侧列表里应出现 **Build iOS IPA (unsigned)**

> 如果左侧啥都没有，说明 workflow 文件不在**默认分支**（这个仓库是 `master`，不是 `main`）上。`workflow_dispatch` 只认默认分支。

## 4. 跑一次编译

1. 左侧点 **Build iOS IPA (unsigned)** → 右侧 **Run workflow** → **Run workflow**
2. 三个参数保持默认（见下方说明），点绿色按钮
3. 等 **3~6 分钟**（首次会久一点），出现绿色 ✓ 就是成功

| 参数 | 默认 | 作用 |
|---|---|---|
| `configuration` | Release | 构建配置。Release 跑得快、体积小 |
| `uniquify_bundle_id` | **开** | 把 Bundle ID / App Group 改写成 `com.<你的用户名>.jevjarvis`。**建议保持开启**：原作者的 `com.jevchat.jarvis` 如果已在 Apple 注册过，你的免费账号就抢不到，Sideloadly 会直接报错 |
| `adhoc_sign` | **开** | 构建后做一次 ad-hoc 签名，把 App Group 权限写进签名。键盘靠 App Group 读 App 里配的 API Key，这一步能明显提高重签后的成功率 |

## 5. 下载 ipa

构建成功后，进这次运行的页面 → 页面底部 **Artifacts** → 下载 **JevJarvis-unsigned-ipa**（是个 zip）。

解压得到：

| 文件 | 用途 |
|---|---|
| `JevJarvis-unsigned.ipa` | 待签名的安装包 |
| `build-info.txt` | 记录 Bundle ID、版本、SHA256 —— Sideloadly 里核对用 |
| `build.log` | 完整编译日志，失败时才有用 |

> **这个 ipa 可以反复用。** 后面证书 7 天过期了，直接重新跑 Sideloadly 签一次就行，不用重新编译。

## 6. Sideloadly 签名安装

1. iPhone 连上电脑，手机上点 **信任此电脑**
2. 打开 Sideloadly，把 `JevJarvis-unsigned.ipa` 拖进 **IPA** 框
3. **Apple ID** 填你的 Apple ID（免费账号就行）
4. 点 **Start**
   - 会要你的 Apple ID 密码 → 输
   - 开了双重认证的话，会给你的其他 Apple 设备推验证码 → 填
5. 等进度条走完（1~3 分钟），提示成功

### iPhone 上收尾

1. **设置 → 通用 → VPN与设备管理 → 开发者 App** → 选你的 Apple ID → **信任**
2. 打开 **Jev Jarvis** App，能进去就说明装好了

## 7. 启用键盘（手机上操作）

1. **设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Jev 键盘**
2. 回到键盘列表，点 **Jev 键盘** → 打开 **允许完全访问**
   - **必须开**。键盘要联网调模型、要读剪贴板，不开就完全没法用
3. 打开 Jev Jarvis App → **模型**页填配置（见下）→ 点 **测试连接**
4. 到 **试一试** 页跑一条，通了就是全通了

## 8. 填 API 配置（复用你现有的两把 key）

| 层 | 选哪个预设 | 填什么 |
|---|---|---|
| **生成层**（起草回复） | `DeepSeek 官方` | Base `https://api.deepseek.com`，模型 `deepseek-chat`，Key = 你的 `sk-9761...` |
| **判断层**（意图/风险/排序） | `OpenRouter 网关` | Base `https://openrouter.ai/api/alpha/decisions`，模型 `typesafe/jev-1.13`，Key = 你的 `sk-or-v1-21ff...` |

配置存在 App Group 私有容器里，App 和键盘共享，改完立刻生效、不用重启键盘。

---

## 排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| Actions 页看不到 workflow | fork 没启用 Actions，或文件不在 `master` | 按第 3 步启用；确认文件在默认分支 |
| 构建失败：`requires a provisioning profile` | 签名没关干净 | 用仓库里附带的 workflow 原样跑，别自己删 `CODE_SIGNING_ALLOWED=NO` |
| 步骤「定位 .app」报找不到 | 产物路径和预期不一致 | workflow 里已有 fallback 搜索；仍失败就把 `build.log` 贴出来 |
| 报「键盘扩展没被嵌入」 | 扩展 target 没被构建 | 把 `build.log` 给作者，这是工程层面的问题 |
| Sideloadly：`This app ID is not available` / 注册 Bundle ID 失败 | 原 Bundle ID 已被作者注册 | 重跑 workflow，确认 `uniquify_bundle_id` 是**开**的 |
| 装完 App 打不开、图标灰 | 证书没信任，或已过 7 天 | 先去设置里信任；过期就重新 Sideloadly 签一次 |
| 键盘列表里找不到 Jev 键盘 | 键盘扩展没添加 | 设置 → 通用 → 键盘 → 添加新键盘 |
| 键盘出来了，点「分析剪贴板」没反应 | 没开「允许完全访问」，或 key 没填 | 打开完全访问；App 内「模型」页点测试连接 |
| 键盘能出候选，但点候选插不进输入框 | 完全访问被系统自动关掉了 | 重新打开（系统在键盘更新后会重置这个开关） |

---

## 关于「7 天过期」这件事

免费 Apple ID 签名的 App **7 天后失效**：App 打不开、键盘消失。到期做一次：

1. 打开 Sideloadly（ipa 还在老地方，不用重新下载）
2. 拖进去，Start，重签
3. 手机上重新信任一次

**没有别的免费办法绕开** —— 这是 Apple 的机制。如果打算长期天天用，两条路更省事：

| 方案 | 成本 | 效果 |
|---|---|---|
| **买个人开发者账号** | $99/年 | 证书 1 年有效，不再 7 天一签；还能上 TestFlight 给朋友用 |
| **跟作者要 TestFlight 名额** | 0 | 作者有付费账号的话，一个 TestFlight build 90 天有效，完全不用自己编译 |

作者正在准备上架（仓库里有整套 App Store 截图和 `docs/TESTFLIGHT.md` 发布手册），要名额走 README 里的公众号私信。
