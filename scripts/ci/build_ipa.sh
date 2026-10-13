#!/usr/bin/env bash
# 无签名构建 + 打包 ipa（给没有 Mac 的人用）
#
# 这段逻辑原本散在 .github/workflows/build-ios-unsigned.yml 的多个 step 里。
# 现在 ci.yml / release.yml / build-ios-unsigned.yml 三处都要用，抽出来共用，
# 免得改一处忘两处、慢慢漂移。
#
# 只做「编译 -> 定位产物 -> ad-hoc 签名 -> 打包 ipa -> 写 build-info.txt」，
# 不碰 git、不碰网络。搬运产物是调用方的事。
#
# 环境变量（全部有默认值）：
#   CONFIG        Release | Debug                                  默认 Release
#   PROJECT       xcodeproj 路径                                   默认 JevJarvis.xcodeproj
#   SCHEME        主命令用的 scheme                                默认 JevJarvis
#   TARGET        兜底用的 target 名 + 产物 .app 名                 默认 JevJarvis
#   DERIVED       -derivedDataPath                                默认 build/dd
#   LOG           编译日志落盘路径                                  默认 build.log
#   ADHOC_SIGN    1=做 ad-hoc 签名并把 App Group 写进签名           默认 1
#   OUT_IPA       ipa 输出路径                                     默认 JevJarvis-unsigned.ipa
#   INFO_FILE     build-info.txt 输出路径                          默认 build-info.txt
#
# 产出：$OUT_IPA、$INFO_FILE、$LOG，并把 APP_PATH 写入 $GITHUB_ENV（若存在）

set -euo pipefail

CONFIG="${CONFIG:-Release}"
PROJECT="${PROJECT:-JevJarvis.xcodeproj}"
SCHEME="${SCHEME:-JevJarvis}"
TARGET="${TARGET:-JevJarvis}"
DERIVED="${DERIVED:-build/dd}"
LOG="${LOG:-build.log}"
ADHOC_SIGN="${ADHOC_SIGN:-1}"
OUT_IPA="${OUT_IPA:-JevJarvis-unsigned.ipa}"
INFO_FILE="${INFO_FILE:-build-info.txt}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# 日志同时在 CI 控制台可见、又落盘（落盘的那份会被推到 ci-log 分支供远程诊断）
: > "$LOG"
mark() { echo "$*" | tee -a "$LOG"; }

# 注意：`find | head -1` 在 pipefail 下会因 find 收 SIGPIPE(141) 把脚本带崩，
# 所以每一处 `find ... | head -1` 都必须带 `|| true`。
first_appex() {
  find "$1" -maxdepth 1 -name '*.appex' 2>/dev/null | head -1 || true
}

mark "########## 构建开始 ##########"
mark "配置=${CONFIG}  scheme=${SCHEME}  target=${TARGET}  adhoc_sign=${ADHOC_SIGN}"
mark "仓库=$(pwd)"
mark "时间=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------- 1. 编译

attempt() {
  local label="$1"; shift
  mark ""
  mark "########## 编译尝试：${label} ##########"
  mark "########## xcodebuild -project ${PROJECT} -sdk iphoneos -configuration ${CONFIG} CODE_SIGNING_ALLOWED=NO $* build"
  # 显式 if/return，不依赖 set -e 在函数内的传播规则
  if xcodebuild -project "$PROJECT" -sdk iphoneos \
       -configuration "$CONFIG" \
       CODE_SIGNING_ALLOWED=NO \
       "$@" build >> "$LOG" 2>&1; then
    return 0
  fi
  return 1
}

BUILD_MODE=""
# 主命令：-scheme + -derivedDataPath。
# 注意别用 -target 配 -derivedDataPath —— xcodebuild 会直接报
# "The flag -scheme, -testProductsPath, or -xctestrun is required
#  when specifying -derivedDataPath"（2026-09-30 实测踩过）。
# -derivedDataPath 的好处是产物路径固定，后面定位 .app 不用猜 DerivedData。
if attempt "主命令：-scheme ${SCHEME} + -derivedDataPath ${DERIVED}" \
     -scheme "$SCHEME" -derivedDataPath "$DERIVED"; then
  BUILD_MODE="scheme"
  mark ">>> 结果：编译成功（-scheme 主命令）"
elif attempt "兜底：作者官方写法 -target ${TARGET}" -target "$TARGET"; then
  BUILD_MODE="target"
  mark ">>> 结果：编译成功（-target 兜底，产物在 DerivedData）"
else
  mark ">>> 结果：两种写法都失败"
  # 把报错行摊到 annotation 上：Actions 日志要登录才能看，annotation 匿名可读
  grep -E "error: " "$LOG" | head -10 | while IFS= read -r line; do
    echo "::error title=xcodebuild::$line"
  done || true
  echo "::error title=编译失败::xcodebuild 两种写法都失败，详见 build.log"
  exit 1
fi

# ---------------------------------------------------------------- 2. 定位 .app

APP=""
if [ "$BUILD_MODE" = "scheme" ]; then
  APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "${TARGET}.app" -type d 2>/dev/null | head -1 || true)
fi
if [ -z "$APP" ]; then
  APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "${TARGET}.app" \
        -path "*${CONFIG}-iphoneos*" -type d 2>/dev/null | head -1 || true)
fi
if [ -z "$APP" ]; then
  echo "::error title=定位产物失败::构建报告成功，但找不到 ${TARGET}.app"
  exit 1
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
mark ""
mark "产物路径：$APP"
ls -la "$APP" | tee -a "$LOG"

# 键盘扩展必须嵌在 PlugIns 这一层。少了它 ipa 是「能装但没键盘」的废包，
# 而这种失败在本地往往看不出来 —— 必须显式断言。
APPEX="$(first_appex "$APP/PlugIns")"
if [ -z "$APPEX" ]; then
  echo "::error title=产物不完整::$APP/PlugIns 下没有任何 .appex —— 键盘扩展没被嵌入，包是废的"
  exit 1
fi
mark "键盘扩展：$APPEX"
ls -la "$APP/PlugIns" | tee -a "$LOG"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "APP_PATH=$APP" >> "$GITHUB_ENV"
fi

# ---------------------------------------------------------------- 3. ad-hoc 签名

if [ "$ADHOC_SIGN" = "1" ]; then
  mark ""
  mark "########## ad-hoc 签名（把 App Group 权限写进签名）##########"
  APP_ENT="App/JevJarvis.entitlements"
  KB_ENT="Keyboard/JevKeyboard.entitlements"

  # 顺序不能反：先签内嵌的 extension，再签外层 App。反过来外层签名会失效。
  sign_one() {
    local path="$1" ent="$2" label="$3"
    if ! codesign -f -s - --timestamp=none --entitlements "$ent" "$path" >> "$LOG" 2>&1; then
      echo "::error title=ad-hoc 签名::${label} 签名失败，详见 build.log"
      exit 1
    fi
    mark "已签名 ${label}"
  }
  sign_one "$APPEX" "$KB_ENT" "键盘扩展"
  sign_one "$APP" "$APP_ENT" "宿主 App"

  # 断言权限真的落进签名了。之前只打印不断言，签失败也照样出包。
  ENT_DUMP="$(codesign -d --entitlements - "$APP" 2>&1 || true)"
  mark "外层签名权限："
  mark "$ENT_DUMP"
  WANT_GROUP="$(sed -n 's/.*<string>\(group\.[^<]*\)<\/string>.*/\1/p' "$APP_ENT" | head -1 || true)"
  if [ -n "$WANT_GROUP" ] && ! printf '%s' "$ENT_DUMP" | grep -q "$WANT_GROUP"; then
    echo "::error title=ad-hoc 签名::签名里没找到 App Group ${WANT_GROUP} —— 重签后键盘读不到配置"
    exit 1
  fi
  mark "ad-hoc 签名完成，App Group ${WANT_GROUP} 已写入"
fi

# ---------------------------------------------------------------- 4. 打包 ipa

mark ""
mark "########## 打包 ipa ##########"
rm -rf ipa && mkdir -p ipa/Payload
cp -R "$APP" ipa/Payload/
(cd ipa && zip -qry "../${OUT_IPA}" Payload)
ls -lh "$OUT_IPA" | tee -a "$LOG"

# ---------------------------------------------------------------- 5. build-info.txt

PB=/usr/libexec/PlistBuddy
read_plist() { "$PB" -c "Print :$2" "$1" 2>/dev/null || echo "(缺)"; }

APP_ID="$(read_plist "$APP/Info.plist" CFBundleIdentifier)"
VER="$(read_plist "$APP/Info.plist" CFBundleShortVersionString)"
BLD="$(read_plist "$APP/Info.plist" CFBundleVersion)"
MIN="$(read_plist "$APP/Info.plist" MinimumOSVersion)"
KB_ID="$(read_plist "$APPEX/Info.plist" CFBundleIdentifier)"

# 直接从源文件读，别用 Bundle ID 做字符串推导（关掉改写开关时会算错）
APP_GROUP="$(sed -n 's/.*<string>\(group\.[^<]*\)<\/string>.*/\1/p' App/JevJarvis.entitlements | head -1 || true)"

{
  echo "构建时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "提交: ${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo '未知')}"
  echo "配置: ${CONFIG}"
  echo "宿主 App Bundle ID : ${APP_ID}"
  echo "键盘扩展 Bundle ID: ${KB_ID}"
  echo "App Group: ${APP_GROUP}"
  echo "主版本: ${VER} (build ${BLD})"
  echo "最低系统: iOS ${MIN}"
  echo ""
  echo "Sideloadly 里 Bundle ID 会自动读出，通常不用手填。"
  echo "App 和键盘扩展必须共用同一个 App Group，上面这行就是它。"
  echo ""
  echo "ipa 大小: $(wc -c < "$OUT_IPA" | tr -d ' ') 字节"
  echo "ipa SHA256:"
  echo "  $(shasum -a 256 "$OUT_IPA" | awk '{print $1}')"
} | tee "$INFO_FILE" | tee -a "$LOG"

mark "########## 构建结束 ##########"
