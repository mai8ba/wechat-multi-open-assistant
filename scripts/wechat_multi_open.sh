#!/bin/bash
# wechat-multi-open — create independent WeChat instances on macOS.
# Design rules: no sudo, no nohup, unique Bundle ID per clone, ad-hoc re-sign.
set -eo pipefail

BASE_ID="com.tencent.xinWeChat"
SRC="/Applications/WeChat.app"
TOTAL=2
DRY_RUN=0
NO_LAUNCH=0
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage: wechat_multi_open.sh [options]

Options:
  --total N      Total simultaneous WeChat instances wanted (2=dual, 3=triple, 4=quad). Default 2.
  --source PATH  Source WeChat.app. Default /Applications/WeChat.app
  --list         Report existing copies, bundle IDs and running PIDs; change nothing.
  --dry-run      Show the plan without changing anything.
  --no-launch    Create copies but do not open them.
  -h, --help     Show this help.

Examples:
  wechat_multi_open.sh --list
  wechat_multi_open.sh --total 2
  wechat_multi_open.sh --total 4 --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --total)
      [ $# -ge 2 ] || { echo "ERROR: --total needs a value" >&2; exit 2; }
      TOTAL="$2"; shift 2 ;;
    --source)
      [ $# -ge 2 ] || { echo "ERROR: --source needs a value" >&2; exit 2; }
      SRC="$2"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$SRC" ]; then
  echo "ERROR: source app not found: $SRC" >&2
  echo "Hint: mdfind \"kMDItemCFBundleIdentifier == 'com.tencent.xinWeChat'\"" >&2
  exit 1
fi

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
pid_of() { pgrep -f "^$1/Contents/MacOS/WeChat\$" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true; }

if [ "$LIST_ONLY" = 1 ]; then
  echo "=== WeChat instances in /Applications ==="
  printf 'source: %s (v%s)\n' "$SRC" "$(plist_get "$SRC" CFBundleShortVersionString)"
  for i in {2..12}; do
    p="/Applications/WeChat${i}.app"
    [ -d "$p" ] || continue
    printf 'slot %-2s path=%-34s bundle=%-28s pid=%s\n' \
      "$i" "$p" "$(plist_get "$p" CFBundleIdentifier)" "$(pid_of "$p" | sed 's/^$/not-running/')"
  done
  echo "=== copies with a conflicting original Bundle ID ==="
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
  exit 0
fi

case "$TOTAL" in
  ''|*[!0-9]*) echo "ERROR: --total must be an integer between 2 and 12" >&2; exit 2 ;;
esac
if [ "$TOTAL" -lt 2 ] || [ "$TOTAL" -gt 12 ]; then
  echo "ERROR: --total must be between 2 and 12" >&2; exit 2
fi
if [ ! -w /Applications ]; then
  echo "ERROR: /Applications is not writable by the current user." >&2
  echo "This workflow is sudo-free by design; use an account whose group can write /Applications." >&2
  exit 1
fi

need=$((TOTAL - 1))
n_created=0
n_reused=0
created_list=""
reuse_list=""

echo "=== Preflight ==="
echo "source=$SRC version=$(plist_get "$SRC" CFBundleShortVersionString) target_total=$TOTAL copies_needed=$need"

for i in {2..12}; do
  [ "$n_created" -ge "$need" ] && break
  p="/Applications/WeChat${i}.app"
  expected="${BASE_ID}${i}"

  if [ -e "$p" ]; then
    actual="$(plist_get "$p" CFBundleIdentifier)"
    if [ "$actual" != "$expected" ]; then
      echo "ERROR: $p exists but its Bundle ID is '$actual' (expected '$expected')." >&2
      echo "Refusing to overwrite. Remove or rename it manually, then re-run." >&2
      exit 3
    fi
    clone_ver="$(plist_get "$p" CFBundleShortVersionString)"
    src_ver="$(plist_get "$SRC" CFBundleShortVersionString)"
    if [ "$clone_ver" != "$src_ver" ]; then
      echo "WARNING: $p is v$clone_ver while source is v$src_ver; delete this slot to rebuild after upgrade." >&2
    fi
    n_reused=$((n_reused+1))
    reuse_list="${reuse_list}${p}\n"
    echo "reuse  $p (valid clone, v$clone_ver)"
    continue
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "create $p -> $expected (dry-run)"
    n_created=$((n_created+1))
    continue
  fi

  echo "create $p -> $expected"
  cp -R "$SRC" "$p"
  xattr -dr com.apple.quarantine "$p" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $expected" "$p/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName 微信分身${i}" "$p/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 微信分身${i}" "$p/Contents/Info.plist"
  codesign --force --deep --sign - "$p"
  codesign --verify --deep --strict "$p"
  n_created=$((n_created+1))
  created_list="${created_list}${p}\n"
  if [ "$NO_LAUNCH" = 0 ]; then
    open "$p"
    echo "launched $p"
  fi
done

if [ "$n_created" -lt "$need" ]; then
  echo "WARNING: only $n_created new copies created; free slots 2..12 exhausted." >&2
fi

echo
echo "=== Result ==="
echo "created=$n_created reused=$n_reused target_total=$TOTAL"
printf '%b' "$created_list" | sed '/^$/d' | sed 's/^/NEW      /'
printf '%b' "$reuse_list"  | sed '/^$/d' | sed 's/^/REUSED   /'
echo
echo "=== Verification ==="
for i in {2..12}; do
  p="/Applications/WeChat${i}.app"
  [ -d "$p" ] || continue
  echo "slot=$i bundle=$(plist_get "$p" CFBundleIdentifier) pid=$(pid_of "$p" | sed 's/^$/not-running/')"
done
echo
echo "Next: scan a QR code with the second account in each clone."
echo "Open the original WeChat.app manually if it is not running; never quit a running instance without asking."
