# CI/CD 设计说明

这套流水线要解决的核心问题不是「跑测试」，而是：
**这个提交能不能编出包、装到手机上还能用？**

这个仓库有三处「手工同步」的脆弱点，任一处不同步都会产出
**能编译、能安装、但装上去是废的** 包 —— 本地几乎看不出来：

| 脆弱点 | 不同步的后果 | 本仓库的兜底 |
|---|---|---|
| App Group 字符串硬编码在 `Shared/JevModel.swift`，同时要写进两份 entitlements | App 往一个自己没权限的 suite 写配置，键盘永远读不到 Key | `verify_project.py` 三方比对 |
| `project.pbxproj` 用**显式** `PBXFileReference`（不是 Xcode 16 的 FileSystemSynchronizedRootGroup），新增 .swift 要手工登记 6 处 | `cannot find 'X' in scope`；磁盘上文件明明在，肉眼极难发现 | `verify_project.py` 磁盘 ↔ pbxproj 双向比对 |
| `Info.plist` / `*.entitlements` 由 `xcodegen` 从 `project.yml` 生成 | 手改生成物会被下次 `xcodegen generate` 悄悄冲掉 | 关键键 + 版本号变量校验 |

所以 CI 的第一层不是测试，是**静态一致性**。它 20 秒就能跑完，比花 3 分钟 macOS runner 编出个废包划算得多。

---

## 四个工作流的分工

| 工作流 | 触发 | 耗时 | 职责 | 阻塞合并 |
|---|---|---|---|---|
| `ci.yml` | PR / push 到 master、main / 手动 | ~4 分钟 | 工程一致性 → 逻辑回归 → 无签名构建 | ✅ 是 |
| `ui-tests.yml` | 每夜 / 手动 / PR 打 `run-ui-tests` 标签 | ~15 分钟 | 模拟器上跑 XCUITest | ❌ 否 |
| `release.yml` | 推 `v*` tag / 手动 | ~5 分钟 | 出 ipa → GitHub Release + builds 分支 + ci-log 分支 | — |
| `build-ios-unsigned.yml` | 手动 / push 到自身或 `scripts/ci/**` | ~4 分钟 | 给「任何 fork 后没有 Mac 的人」的自助出包入口 | — |

### `ci.yml` —— 三层，从便宜到贵

```
① 工程一致性   ubuntu-latest   ~20 秒   静态检查，抓「能编译但装了没用」
② 逻辑回归     macos-15        ~1 分钟  PromptCheck：URL 拼接 / 候选清洗 / prompt 占位符 / 风险映射
③ 无签名构建   macos-15        ~3 分钟  真编一遍 + ad-hoc 签名 + 打包，断言键盘扩展嵌进去了
```

②③ 用 `needs:` 串起来：① 挂了就不启动 macOS runner，省额度。

第 ③ 层之后还会跑一次 ad-hoc 签名并**断言 App Group 真的进了签名**。
这一步失败在本地很难发现（Xcode 照样出包），但装到手机上键盘就是读不到配置。

### `ui-tests.yml` —— 为什么不当门禁

`AutoLaunchTests` 要真的进系统设置添加第三方键盘、长按地球键选键盘、等键盘扩展冷启动。
这条链路跨 Settings 和 SpringBoard 两个系统 App 的 UI 层级，**苹果每次改系统 UI 都可能让选择器失效**。

拿它当门禁的结果是：「设置界面小改」这种无关提交也变红，最后大家就学会忽略红了 —— 比没有门禁更糟。
所以它独立、按需触发、结果只做参考。失败时优先看 artifact 里的 `uitest.log` 与 `TestResults-*.xcresult`。

---

## 目录结构

```
.github/workflows/
  ci.yml                    质量门禁：一致性 + 逻辑回归 + 构建
  ui-tests.yml              模拟器 UI 测试（非阻塞）
  release.yml               出包发布：GitHub Release + builds 分支
  build-ios-unsigned.yml    无 Mac 自助出包入口

scripts/ci/
  verify_project.py         工程一致性静态校验（纯标准库，可本地跑）
  check_workflows.py        workflow 与脚本自查（YAML/run 块/标量陷阱/脚本语法）
  uniquify_bundle_id.py     Bundle ID / App Group 改写 + 一致性断言
  build_ipa.sh              编译 → 定位产物 → ad-hoc 签名 → 打包 → build-info.txt
  push_to_branch.sh         把产物推到 builds / ci-log 分支（带重试）
  pick_simulator.py         从 simctl 输出里挑一台可用模拟器
```

「编译、打包」的逻辑只有 `build_ipa.sh` 一份，`ci.yml` / `release.yml` /
`build-ios-unsigned.yml` 三处共用 —— 否则同一套逻辑三份拷贝，迟早漂移。

---

## 本地跑同样的检查

不用等 CI，在 Windows 上也能跑掉最便宜、最常挂的那一层：

```bash
# 工程一致性（唯一不需要 Mac 的一项，也是最常挂的一项）
python3 scripts/ci/verify_project.py

# workflow 与脚本自查：YAML 解析 + run 块 bash 语法 + 裸标量陷阱 + 脚本语法
# （改了 .github/workflows/*.yml 或 scripts/ci/* 之后务必跑一遍）
python3 scripts/ci/check_workflows.py
```

`verify_project.py` 每个 error 都会同时发一条 GitHub annotation。
**annotation 是唯一匿名可读的排查通道** —— Actions 日志下载必须登录 GitHub，
而 `curl api.github.com/repos/<owner>/<repo>/check-runs/<job_id>/annotations` 不用。

另外 `macos-15` runner 上还能跑逻辑回归，和 CI 用同一条命令：

```bash
swiftc -o /tmp/jevcheck tools/PromptCheck/main.swift Shared/*.swift && /tmp/jevcheck
```

---

## 发布流程

```bash
# 1. 改版本号（两处要一起改，CI 会校验一致性）
#    project.yml:  MARKETING_VERSION / CURRENT_PROJECT_VERSION
#    pbxproj 由 xcodegen 生成，改完 project.yml 后跑 xcodegen generate

# 2. 打 tag 推上去，发布流水线自动跑
git tag v0.1.0
git push origin v0.1.0
```

跑完会得到三个去向：

| 去向 | 用途 |
|---|---|
| GitHub Release（挂 ipa + build-info + build.log） | 正式发布、留档 |
| `builds` 分支 | 一条 raw 链接，手机 Safari 直接下载（免电脑签名的入口） |
| `ci-log` 分支 | 构建日志 + ipa 备份，没有 Mac 的人远程诊断用 |

手动触发 `release.yml` 时，勾上「创建 Release」就必须填 tag，否则会明确报错停下。

---

## 权限与 Secrets

| 名称 | 用途 | 需要手动配置吗 |
|---|---|---|
| `secrets.GITHUB_TOKEN` | 推 builds / ci-log 分支、建 Release | ❌ 自动注入 |

`permissions: contents: write` 只给需要写分支与 Release 的 job，`ci.yml` 保持只读。

**不需要任何 Apple 证书、描述文件或付费账号** —— 全程只产未签名 ipa，
签名留给你自己的机器（Sideloadly）或手机（Feather / ESign / SideStore）。

---

## 已知限制

- **UI 测试会抖。** 见上，它遍历系统设置，苹果改 UI 就会失效。这是设计上的取舍，
  不是可以「修好」的东西 —— 修的方式只是把选择器写得更宽容。
- **免费 Apple ID 不支持 App Group。** 这是苹果账号能力限制（Personal Team 不发放该能力），
  不是签名工具的问题。所以别把「App 填 Key → 键盘读取」当默认路径，
  走键盘内直接填（长按键盘 → 🔑 面板）或配置串粘贴。详见 `docs/CLOUD-BUILD.md`。
- **CI 只验到「能编出正确的包」。** 键盘装到真机上能不能弹出来、配置能不能读到，
  仍然需要真机验证 —— 这一环没法自动化（要真设备 + 真人去系统设置里开权限）。
- **模拟器 UI 测试有两种签名模式。** 主尝试用工程默认签名（App Group 生效，更接近真机）；
  失败则兜底完全关签名（主断言仍可验证，但 App Group 不生效）。
  实际用的哪种会写在 job 汇总里。
