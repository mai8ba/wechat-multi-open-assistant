#!/bin/bash
# Mac微信多开助理 — 创建相互隔离的微信实例。
# 安全模型（审核要求）：
#   1. 默认只读：不带 --apply 时仅输出检查结果与完整变更计划，绝不写任何文件。
#   2. 显式授权：--apply 必须同时提供 --confirm-plan <planId> 与 --confirm-steps <csv>。
#      每个高风险步骤（copy/xattr/plist/codesign/launch）必须被逐项明确确认，
#      未列入的步骤一律跳过，脚本不会自动执行。
#   3. 安全边界：不 kill 任何进程；不在运行中的槽位上改动；不读取聊天数据目录内容。
#   4. 可回滚：每个模式都输出回滚步骤，另提供 --rollback-plan N（只读）。
#   5. 付费前置：--apply 必须先校验支付宝 AI 付签发的一次性授权 token，
#      验签/过期/已使用任一不满足则拒绝执行，绝不绕过。
set -eo pipefail

BASE_ID="com.tencent.xinWeChat"
SRC="/Applications/WeChat.app"
TOTAL=2
MODE="plan"
LIST_ONLY=0
ROLLBACK_SLOT=""
CONFIRM_PLAN=""
CONFIRM_STEPS=""
NO_LAUNCH=0
AUTH_TOKEN="${AUTH_TOKEN:-}"
AUTH_PUBLIC_KEY_PATH="${AUTH_PUBLIC_KEY_PATH:-}"
AUTH_TOKEN_LEDGER="${AUTH_TOKEN_LEDGER:-}"

usage() {
  cat <<'EOF'
Usage: wechat_multi_open.sh <mode> [options]

Modes (one of):
  --list                 只读：列出现有实例、Bundle ID、运行 PID、冲突副本
  --plan                 只读（默认）：输出完整变更计划与 planId，不修改任何东西
  --apply                执行：必须配合 --confirm-plan 与 --confirm-steps
  --rollback-plan N      只读：输出第 N 个槽位的回滚步骤

Options:
  --total N              期望同时在线的实例总数（含原版），2=双开 3=三开 4=四开，默认 2
  --source PATH          源 WeChat.app，默认 /Applications/WeChat.app
  --confirm-plan <id>    --apply 必填：本次计划输出中的 planId
  --confirm-steps <csv>  --apply 必填：已获用户逐项确认的步骤，逗号分隔
                         可选值：copy,xattr,plist,codesign,launch
  --no-launch            即使确认了 launch 也不启动（安全优先时可加）
  --auth-token <token>   支付宝 AI 付授权 token（敏感，建议改用环境变量 AUTH_TOKEN）
  --auth-public-key <path>  授权公钥 PEM 文件路径（或环境变量 AUTH_PUBLIC_KEY_PATH）
  --auth-token-ledger <path> 本地 token 消费台账（默认 ~/.alipay/auth-token-used.json）
  -h, --help             显示帮助

高风险步骤说明：
  copy     复制 App 到新槽位（覆盖已存在槽位永远被拒绝）
  xattr    仅移除副本上的 com.apple.quarantine 隔离属性
  plist    仅在副本上设置 Bundle ID / 显示名
  codesign 仅对副本做 ad-hoc 重签名并校验
  launch   启动副本（默认建议用户自行启动）

示例：
  wechat_multi_open.sh --list
  wechat_multi_open.sh --plan --total 3
  wechat_multi_open.sh --apply --total 3 --confirm-plan <id> --confirm-steps copy,xattr,plist,codesign
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_ONLY=1; shift ;;
    --plan) MODE="plan"; shift ;;
    --apply) MODE="apply"; shift ;;
    --rollback-plan)
      [ $# -ge 2 ] || { echo "ERROR: --rollback-plan needs a slot number" >&2; exit 2; }
      ROLLBACK_SLOT="$2"; shift 2 ;;
    --total)
      [ $# -ge 2 ] || { echo "ERROR: --total needs a value" >&2; exit 2; }
      TOTAL="$2"; shift 2 ;;
    --source)
      [ $# -ge 2 ] || { echo "ERROR: --source needs a value" >&2; exit 2; }
      SRC="$2"; shift 2 ;;
    --confirm-plan)
      [ $# -ge 2 ] || { echo "ERROR: --confirm-plan needs a value" >&2; exit 2; }
      CONFIRM_PLAN="$2"; shift 2 ;;
    --confirm-steps)
      [ $# -ge 2 ] || { echo "ERROR: --confirm-steps needs a value" >&2; exit 2; }
      CONFIRM_STEPS="$2"; shift 2 ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    --auth-token)
      [ $# -ge 2 ] || { echo "ERROR: --auth-token needs a value" >&2; exit 2; }
      AUTH_TOKEN="$2"; shift 2 ;;
    --auth-public-key)
      [ $# -ge 2 ] || { echo "ERROR: --auth-public-key needs a value" >&2; exit 2; }
      AUTH_PUBLIC_KEY_PATH="$2"; shift 2 ;;
    --auth-token-ledger)
      [ $# -ge 2 ] || { echo "ERROR: --auth-token-ledger needs a value" >&2; exit 2; }
      AUTH_TOKEN_LEDGER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
pid_of() { pgrep -f "^$1/Contents/MacOS/WeChat\$" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true; }

if [ -n "$ROLLBACK_SLOT" ]; then
  case "$ROLLBACK_SLOT" in
    ''|*[!0-9]*) echo "ERROR: --rollback-plan needs an integer slot (2..12)" >&2; exit 2 ;;
  esac
  if [ "$ROLLBACK_SLOT" -lt 2 ] || [ "$ROLLBACK_SLOT" -gt 12 ]; then
    echo "ERROR: slot must be between 2 and 12" >&2; exit 2
  fi
  p="/Applications/WeChat${ROLLBACK_SLOT}.app"
  c="~/Library/Containers/${BASE_ID}${ROLLBACK_SLOT}"
  echo "=== 只读回滚计划（未执行任何操作）==="
  echo "1) 由用户在该副本界面内退出登录并退出应用；脚本不会 kill 任何进程。"
  echo "2) 确认没有未发出消息后，将 $p 移到废纸篓（不要直接 rm）。"
  echo "3) 如用户不再需要该账号数据，再由用户自行决定是否清理 ${c}。"
  echo "4) 不要触碰原版 /Applications/WeChat.app 及其容器 ${BASE_ID}。"
  exit 0
fi

if [ ! -d "$SRC" ]; then
  echo "ERROR: source app not found: $SRC" >&2
  echo "Hint: mdfind \"kMDItemCFBundleIdentifier == 'com.tencent.xinWeChat'\"" >&2
  exit 1
fi

if [ "$LIST_ONLY" = 1 ]; then
  echo "=== 只读现状检查 ==="
  printf 'source: %s (v%s)\n' "$SRC" "$(plist_get "$SRC" CFBundleShortVersionString)"
  for i in {2..12}; do
    p="/Applications/WeChat${i}.app"
    [ -d "$p" ] || continue
    printf 'slot %-2s path=%-34s bundle=%-28s pid=%s\n' \
      "$i" "$p" "$(plist_get "$p" CFBundleIdentifier)" "$(pid_of "$p" | sed 's/^$/not-running/')"
  done
  echo "=== 与原版 Bundle ID 冲突的副本（只报告，不处理）==="
  found=0
  for a in /Applications/*.app; do
    [ -d "$a" ] || continue
    [ "$a" = "$SRC" ] && continue
    [ -f "$a/Contents/Info.plist" ] || continue
    if [ "$(plist_get "$a" CFBundleIdentifier)" = "$BASE_ID" ]; then
      echo "CONFLICT: $a"
      found=1
    fi
  done
  [ "$found" = 0 ] && echo "none"
  echo "=== 数据安全边界 ==="
  echo "本模式只读 App 包的 Info.plist，不读取任何聊天数据目录内容。"
  exit 0
fi

case "$TOTAL" in
  ''|*[!0-9]*) echo "ERROR: --total must be an integer between 2 and 12" >&2; exit 2 ;;
esac
if [ "$TOTAL" -lt 2 ] || [ "$TOTAL" -gt 12 ]; then
  echo "ERROR: --total must be between 2 and 12" >&2; exit 2
fi

# ---------- 只读规划：计算槽位与 planId ----------
src_ver="$(plist_get "$SRC" CFBundleShortVersionString)"
slots=""
conflicts=""
running_targets=""
reused=""
free_count=0

for i in {2..12}; do
  p="/Applications/WeChat${i}.app"
  expected="${BASE_ID}${i}"
  if [ -e "$p" ]; then
    actual="$(plist_get "$p" CFBundleIdentifier)"
    if [ "$actual" != "$expected" ]; then
      conflicts="${conflicts}${p} (bundle=${actual}, expected=${expected})\n"
      continue
    fi
    pid="$(pid_of "$p")"
    if [ -n "$pid" ]; then
      running_targets="${running_targets}${p} pid=${pid}\n"
    fi
    reused="${reused}${i},"
    continue
  fi
  free_count=$((free_count+1))
done

# 已有合规副本计入总数，避免重复运行时越建越多
existing_count=0
for x in ${reused//,/ }; do [ -n "$x" ] && existing_count=$((existing_count+1)); done
need=$((TOTAL - 1 - existing_count))
[ "$need" -lt 0 ] && need=0

# 只挑选前 need 个空闲槽位作为本次变更对象
picked=0
IFS=',' read -r -a all_free <<< "$(for i in {2..12}; do
  [ -e "/Applications/WeChat${i}.app" ] || printf '%s,' "$i"
done)"
for s in "${all_free[@]}"; do
  [ -z "$s" ] && continue
  [ "$picked" -ge "$need" ] && break
  if [ -z "$slots" ]; then slots="$s"; else slots="${slots},${s}"; fi
  picked=$((picked+1))
done

slot_list="$(printf '%s' "$slots" | tr ',' ' ')"
plan_raw="plan|src=$SRC|v=$src_ver|total=$TOTAL|slots=$slot_list"
plan_id="$(printf '%s' "$plan_raw" | shasum -a 256 | cut -c1-16)"

step_confirmed() {
  case ",${CONFIRM_STEPS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== 只读预检 ==="
echo "source=$SRC version=$src_ver target_total=$TOTAL existing_clones=$([[ -z "$reused" ]] && echo 0 || echo ${reused%,}) new_slots_needed=$need free_slots_available=$free_count new_slots_to_create=${slots:-none}"
echo "planId=$plan_id"
[ -n "$conflicts" ] && { echo "=== 冲突槽位（不会覆盖）==="; printf '%b' "$conflicts"; }
[ -n "$running_targets" ] && { echo "=== 运行中槽位（不会改动）==="; printf '%b' "$running_targets"; }

if [ "$MODE" = "plan" ]; then
  echo
  echo "=== 完整变更计划（只读，未修改任何文件）==="
  if [ "$free_count" -lt "$need" ]; then
    echo "ERROR: 空闲槽位不足（需要 $need，可用 $free_count）。先清理或选择更小的 --total。" >&2
    exit 4
  fi
  if [ -n "$reused" ]; then
    echo "--- 已存在的合规副本：仅复用，不改动、不覆盖 ---"
    echo "  slots: ${reused%,}"
  fi
  IFS=',' read -r -a slot_arr <<< "$slots" || true
  for s in "${slot_arr[@]}"; do
    [ -z "$s" ] && continue
    p="/Applications/WeChat${s}.app"
    expected="${BASE_ID}${s}"
    echo "--- slot $s ---"
    echo "  [copy]     cp -R $SRC $p          # 仅新建，不覆盖任何已存在目录"
    echo "  [xattr]    xattr -dr com.apple.quarantine $p   # 仅作用于副本"
    echo "  [plist]    CFBundleIdentifier=$expected; CFBundleName/CFBundleDisplayName=微信分身${s}   # 仅副本"
    echo "  [codesign] codesign --force --deep --sign - $p && codesign --verify --deep --strict $p"
    echo "  [launch]   open $p                # 建议留给用户自行执行"
    echo "  data:      ~/Library/Containers/${expected}  （与其他实例隔离）"
  done
  echo
  echo "=== 逐项确认要求 ==="
  echo "以上每个高风险步骤都必须由用户明确确认；未确认的步骤在 --apply 时会被跳过。"
  echo "确认后携带本 planId 执行，例如："
  echo "  wechat_multi_open.sh --apply --total $TOTAL --confirm-plan $plan_id --confirm-steps copy,xattr,plist,codesign"
  echo
  echo "=== 回滚（只读命令，可随时查看）==="
  echo "  wechat_multi_open.sh --rollback-plan <slot>"
  echo "原则：先由用户在界面退出并确认无未发消息 → 把副本移到废纸篓 → 数据目录由用户自行决定。"
  echo "脚本不会 kill 进程，不会 rm 任何文件，不会读取聊天数据内容。"
  exit 0
fi

# ---------- apply：付费授权 + 显式授权后才执行 ----------
# 付费前置：任何修改类操作都必须先通过一次性 token 校验，失败即拒绝执行。
if [ -n "$WECHAT_MULTI_OPEN_AUTH_TOKEN" ] && [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN="$WECHAT_MULTI_OPEN_AUTH_TOKEN"
fi
if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: --apply 必须先完成支付宝 AI 付并通过授权 token 校验；未提供 token。" >&2
  echo "先向付费端点请求资源，完成支付后取得 authorization_token 再执行。" >&2
  exit 9
fi
if [ -z "$AUTH_PUBLIC_KEY_PATH" ]; then
  echo "ERROR: 缺少授权公钥路径，请用 --auth-public-key 或 AUTH_PUBLIC_KEY_PATH 指定。" >&2
  echo "公钥获取方式：GET http://localhost:3000/aipay/public-key（保存为 PEM 文件）。" >&2
  exit 10
fi

VERIFY_SCRIPT="$(cd "$(dirname "$0")" && pwd)/verify_auth_token.mjs"
verify_cmd=(node "$VERIFY_SCRIPT" --public-key "$AUTH_PUBLIC_KEY_PATH" --resource-id "/demo/a2m/resource")
if [ -n "$AUTH_TOKEN_LEDGER" ]; then
  verify_cmd+=(--ledger "$AUTH_TOKEN_LEDGER")
fi
if ! AUTH_TOKEN="$AUTH_TOKEN" "${verify_cmd[@]}" >/dev/null; then
  echo "ERROR: 授权 token 校验失败（验签/过期/已使用），拒绝执行任何修改。" >&2
  exit 11
fi
echo "=== 授权 token 校验通过（付费前置满足）==="

if [ -z "$CONFIRM_PLAN" ] || [ "$CONFIRM_PLAN" != "$plan_id" ]; then
  echo "ERROR: --apply 必须提供与本次只读计划一致的 --confirm-plan（当前 planId=$plan_id）。" >&2
  echo "先运行 --plan 展示完整计划并取得用户确认，不要直接执行。" >&2
  exit 5
fi
if [ -z "$CONFIRM_STEPS" ]; then
  echo "ERROR: --apply 必须提供 --confirm-steps，逐项列出已获用户明确确认的步骤。" >&2
  echo "可选值：copy,xattr,plist,codesign,launch（未列入的步骤会自动跳过）。" >&2
  exit 6
fi
if [ "$free_count" -lt "$need" ]; then
  echo "ERROR: 空闲槽位不足（需要 $need，可用 $free_count）。" >&2
  exit 4
fi
if [ -n "$conflicts" ]; then
  echo "ERROR: 检测到 Bundle ID 冲突槽位，已停止。请先由用户处理：" >&2
  printf '%b' "$conflicts" >&2
  exit 3
fi
if [ -n "$running_targets" ]; then
  echo "ERROR: 目标槽位中有正在运行的实例，已停止（不改动运行中的 App）：" >&2
  printf '%b' "$running_targets" >&2
  exit 7
fi
if [ ! -w /Applications ]; then
  echo "ERROR: /Applications 不可写；本流程刻意不使用 sudo。" >&2
  exit 1
fi
if step_confirmed copy && ! step_confirmed plist; then
  echo "ERROR: 已确认 copy 但未确认 plist；副本可能带有冲突 Bundle ID，拒绝执行。" >&2
  exit 8
fi

echo "=== 执行（仅执行已获逐项确认的步骤）==="
IFS=',' read -r -a slot_arr <<< "$slots" || true
for s in "${slot_arr[@]}"; do
  [ -z "$s" ] && continue
  p="/Applications/WeChat${s}.app"
  expected="${BASE_ID}${s}"
  echo "--- slot $s -> $p ---"

  if step_confirmed copy; then
    if [ -e "$p" ]; then
      echo "  [copy] SKIP：目标已存在，绝不覆盖。"
    else
      cp -R "$SRC" "$p"
      echo "  [copy] DONE"
    fi
  else
    echo "  [copy] SKIP：未获用户确认。"
    continue
  fi

  if step_confirmed xattr; then
    xattr -dr com.apple.quarantine "$p" 2>/dev/null || true
    echo "  [xattr] DONE（仅副本）"
  else
    echo "  [xattr] SKIP：未获用户确认。"
  fi

  if step_confirmed plist; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $expected" "$p/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 微信分身${s}" "$p/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 微信分身${s}" "$p/Contents/Info.plist"
    echo "  [plist] DONE（$expected）"
  else
    echo "  [plist] SKIP：未获用户确认。"
  fi

  if step_confirmed codesign; then
    codesign --force --deep --sign - "$p"
    codesign --verify --deep --strict "$p"
    echo "  [codesign] DONE（校验通过）"
  else
    echo "  [codesign] SKIP：未获用户确认。"
  fi

  if step_confirmed launch && [ "$NO_LAUNCH" = 0 ]; then
    open "$p"
    echo "  [launch] DONE"
  else
    echo "  [launch] SKIP：未获用户确认或指定了 --no-launch，建议用户自行打开。"
  fi
done

echo
echo "=== 执行后只读验证 ==="
for i in {2..12}; do
  p="/Applications/WeChat${i}.app"
  [ -d "$p" ] || continue
  echo "slot=$i bundle=$(plist_get "$p" CFBundleIdentifier) pid=$(pid_of "$p" | sed 's/^$/not-running/')"
done
echo
echo "回滚命令（只读）：wechat_multi_open.sh --rollback-plan <slot>"
echo "提示：请用户在每个副本中用另一个账号扫码登录；脚本不读取也不记录任何登录凭证。"
