#!/usr/bin/env bash
# 把产物推到指定分支（每次强制覆盖，分支上只保留最新一份）
#
# 两个用途：
#   builds  分支 —— ipa + build-info.txt。免电脑签名（Feather/ESign/SideStore）
#                   都要求「ipa 先在手机上」，而 Actions 产物下载必须登录 GitHub，
#                   手机浏览器上很别扭；推到分支后一条 raw 链接 Safari 直接就能下。
#   ci-log  分支 —— build.log + build-info.txt + ipa，给没有 Mac 的人远程诊断。
#
# 用临时目录建独立历史，而不是在工作区里 `git checkout -B`。
# 后者会把整个仓库树都提交进这个分支（实测就是这样，ci-log 里塞满了源码），
# 而这里只需要几个文件。
#
# 用法：
#   GH_TOKEN=xxx GITHUB_REPOSITORY=owner/repo scripts/ci/push_to_branch.sh builds JevJarvis-unsigned.ipa build-info.txt
#
# 环境变量：
#   GH_TOKEN / GITHUB_TOKEN   鉴权 token
#   GITHUB_REPOSITORY         owner/repo
#   REMOTE_URL                直接指定远端 URL（优先于上面两个）
#   LOG                       诊断追加到哪个日志文件，默认 build.log
#   COMMIT_MSG                自定义提交信息

set -uo pipefail

BRANCH="${1:?用法: push_to_branch.sh <branch> <file> [file...]}"
shift
if [ "$#" -lt 1 ]; then
  echo "至少要给一个文件" >&2
  exit 2
fi

LOG="${LOG:-build.log}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

REMOTE_URL="${REMOTE_URL:-}"
if [ -z "$REMOTE_URL" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "$TOKEN" ]; then
    echo "!! 缺少 GITHUB_REPOSITORY 或 token，无法推送 $BRANCH" >&2
    exit 1
  fi
  REMOTE_URL="https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

MSG="${COMMIT_MSG:-chore(${BRANCH}): run=${GITHUB_RUN_ID:-local} sha=$(printf '%.8s' "${GITHUB_SHA:-local}")}"

WORK="$(mktemp -d)"
ORIG_PWD="$(pwd)"
trap 'rm -rf "$WORK"' EXIT

for f in "$@"; do
  if [ -f "$f" ]; then
    cp "$f" "$WORK/" || echo "!! 复制 $f 失败" >&2
  else
    echo "!! 文件不存在，跳过：$f" >&2
  fi
done

if [ -z "$(ls -A "$WORK" 2>/dev/null)" ]; then
  echo "!! 一个文件都没搬过去，放弃推送 $BRANCH" >&2
  exit 1
fi

cd "$WORK"
git init -q
git checkout -q -b "$BRANCH"
git config user.name "ci-bot"
git config user.email "ci-bot@users.noreply.github.com"
git add -A -f
git commit -q -m "$MSG" || echo "!! 没有可提交的改动" >&2

OK=0
for i in 1 2 3 4 5; do
  if git push -f "$REMOTE_URL" "$BRANCH" > /tmp/push-${BRANCH}.log 2>&1; then
    OK=1
    break
  fi
  echo "第 $i 次推送 $BRANCH 失败，重试…" >&2
  tail -5 "/tmp/push-${BRANCH}.log" >&2 || true
  sleep 6
done

# 把成败写进调用方的 build.log，这样 ci-log 分支上能看到搬运是否成功。
# 之前这一步失败会被 continue-on-error 静默掉：构建是绿的，手机端却拿到旧包。
TARGET_LOG="${ORIG_PWD}/${LOG}"
if [ -f "$TARGET_LOG" ]; then
  {
    echo ""
    echo ">>> $BRANCH 分支推送: $([ "$OK" = 1 ] && echo OK || echo FAILED) (run=${GITHUB_RUN_ID:-local})"
    [ -f "/tmp/push-${BRANCH}.log" ] && tail -25 "/tmp/push-${BRANCH}.log"
  } >> "$TARGET_LOG" 2>/dev/null || true
fi

if [ "$OK" = 1 ]; then
  echo "已推送 $BRANCH 分支（覆盖旧内容，只保留最新一份）"
  echo "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${BRANCH}/$(basename "$1")"
  exit 0
fi

echo "!! $BRANCH 分支推送失败 —— 消费方会拿到旧内容，请看 ci-log 分支尾部" >&2
exit 1
