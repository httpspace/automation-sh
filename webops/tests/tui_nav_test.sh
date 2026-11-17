#!/bin/bash
# tui_nav_test.sh — lib/tui.sh tui_nav_menu 測試（PATH 放假 whiptail，不開真實 TUI）
# 用法: bash webops/tests/tui_nav_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARGS="$WORK/args.log"      # 每次 whiptail 呼叫一段，參數一行一個，段落以 ==CALL== 分隔
QUEUE="$WORK/queue"        # 預設回應，每行 "<rc>|<stdout 選擇>"，依序消耗
mkdir -p "$WORK/bin"

cat > "$WORK/bin/whiptail" <<'STUB'
#!/bin/bash
{ echo "==CALL=="; printf '%s\n' "$@"; } >> "$STUB_ARGS"
line=$(head -n 1 "$STUB_QUEUE"); sed -i '1d' "$STUB_QUEUE"
rc="${line%%|*}"; out="${line#*|}"
[ -n "$out" ] && printf '%s' "$out" >&2   # 真 whiptail 的選擇走 stderr（呼叫端以 3>&1 1>&2 2>&3 轉到 stdout）
exit "$rc"
STUB
chmod +x "$WORK/bin/whiptail"
export STUB_ARGS="$ARGS" STUB_QUEUE="$QUEUE"
export PATH="$WORK/bin:$PATH"

# 載入 tui.sh 需要的最小依賴（不 source common.sh，避免副作用）
webops_version() { echo "0.0.0"; }
# shellcheck source=../lib/tui.sh
source "$HERE/../lib/tui.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

calls() { grep -c '^==CALL==$' "$ARGS"; }
# 第 N 次呼叫的參數（N 從 1 起）
call_args() { awk -v n="$1" '/^==CALL==$/{c++; next} c==n' "$ARGS"; }
has_arg() { call_args "$1" | grep -qxF -- "$2"; }
# 第 N 次呼叫中，某參數的下一個參數
next_of() { call_args "$1" | awk -v k="$2" 'f{print; exit} $0==k{f=1}'; }
# 第 N 次呼叫中，某字串的行號
line_of() { call_args "$1" | grep -nxF -- "$2" | head -n1 | cut -d: -f1; }

reset() { : > "$ARGS"; printf '%s\n' "$@" > "$QUEUE"; }

# --- (a)(b)(c) 選到 __sep__ 重畫，最終回傳下一次的選擇 ---
reset '0|__sep__' '0|__sep__' '0|add'
out=$(tui_nav_menu "進階模式 › 資料庫" "返回" "說明" add "新增" list "列表" back "‹ 返回進階模式"); rc=$?
check "(a) rc=0"                         [ "$rc" -eq 0 ]
check "(a) 選到 __sep__ 重畫後回傳 add（呼叫端收不到 __sep__）" [ "$out" = "add" ]
check "(a) whiptail 共被呼叫 3 次"       [ "$(calls)" -eq 3 ]

check "(b) --notags"                     has_arg 1 "--notags"
check "(b) --ok-button 選擇"             [ "$(next_of 1 --ok-button)" = "選擇" ]
check "(b) --cancel-button 返回"         [ "$(next_of 1 --cancel-button)" = "返回" ]
check "(b) title 帶 crumb"               [ "$(next_of 1 --title)" = "webops › 進階模式 › 資料庫" ]
check "(b) prompt 前有 -- 終止符"        [ "$(next_of 1 --menu)" = "--" ]

L_LIST=$(line_of 1 "list"); L_SEP=$(line_of 1 "__sep__"); L_BACK=$(line_of 1 "back")
check "(c) __sep__ 存在"                 [ -n "$L_SEP" ]
check "(c) 分隔線在最後一般項之後"       [ "$L_SEP" -gt "$L_LIST" ]
check "(c) 分隔線緊接返回項之前（label 隔 1 行）" [ "$L_BACK" -eq $((L_SEP + 2)) ]
check "(c) 分隔線 label"                 has_arg 1 "─────────────"

# --- crumb 為空：title 不帶 › ---
reset '0|quit'
out=$(tui_nav_menu "" "離開" "狀態" ov "一覽" quit "✕ 離開 webops")
check "空 crumb：title = webops v<ver>"  [ "$(next_of 1 --title)" = "webops v0.0.0" ]
check "空 crumb：cancel-button 離開"     [ "$(next_of 1 --cancel-button)" = "離開" ]

# --- (d) 取消回傳非零且 stdout 空 ---
reset '1|'
out=$(tui_nav_menu "x" "返回" "p" a "A" back "B"); rc=$?
check "(d) 取消 rc != 0"                 [ "$rc" -ne 0 ]
check "(d) 取消 stdout 空"               [ -z "$out" ]

# --- 取消發生在選過 __sep__ 之後也要 rc != 0 ---
reset '0|__sep__' '1|'
out=$(tui_nav_menu "x" "返回" "p" a "A" back "B"); rc=$?
check "(d) __sep__ 後取消 rc != 0"       [ "$rc" -ne 0 ]

# --- 只有返回項（1 組）也不壞 ---
reset '0|back'
out=$(tui_nav_menu "x" "返回" "p" back "B")
check "只有返回項時回傳 back"            [ "$out" = "back" ]

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
