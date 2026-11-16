#!/bin/bash
# db_engine_test.sh — lib/db.sh 引擎切換測試（PATH stub，不碰真實 DB）
# 用法: bash webops/tests/db_engine_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/db.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/calls.log"
REAL_PATH="$PATH"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check() { # check <desc> <cmd...>
    local d="$1"; shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
has_line() { grep -qxF -- "$1" "$LOG"; }
msgs_has() { [[ "$TUI_MSGS" == *"$1"* ]]; }
msgs_lacks() { [[ "$TUI_MSGS" != *"$1"* ]]; }
has_prefix() { grep -q -- "^$1" "$LOG"; }

# 建立 stub bin：make_stubs <dir> <cmd>...  每個 stub 把 "<name> <args>" 記到 $LOG
make_stubs() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local c
    for c in "$@"; do
        cat > "$dir/$c" <<STUB
#!/bin/bash
echo "$c \$*" >> "$LOG"
case "$c" in
    runuser)  # runuser -u postgres -- <cmd> <args>
        shift 3; exec "\$@" ;;
    psql)     [ "\${STUB_PG_EXISTS:-0}" = 1 ] && echo 1; exit 0 ;;
esac
exit 0
STUB
        chmod +x "$dir/$c"
    done
}

# 最小 PATH：只含 stub 與基本工具所在位置（bash/mktemp/cat/rm 等）
# 為了讓「沒有 mariadb」可成立，先檢查真實環境沒有這些指令
for c in mariadb mysql psql createdb runuser; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "SKIP-ENV: 真實環境已有 $c，無法測「找不到」情境；請在乾淨環境執行"; exit 2
    fi
done

# stub 的 TUI 函式
TUI_MSGS=""
tui_available() { return 0; }
tui_msg() { TUI_MSGS="$TUI_MSGS|$1"; }
tui_yesno() { return 0; }
warn() { TUI_MSGS="$TUI_MSGS|WARN:$1"; }

# shellcheck source=../lib/db.sh
source "$LIB"

run_case() { # run_case <stubdir> <mode>   （其餘環境變數由呼叫端 export）
    : > "$LOG"; TUI_MSGS=""
    PATH="$1:$REAL_PATH" db_create "mvp_Example_com" "$2"
}

# === (1) 引擎未設：mariadb，參數逐字相同 ===
S1="$WORK/s1"; make_stubs "$S1" mariadb mysql psql createdb runuser id getent
unset WEBOPS_DB_ENGINE
run_case "$S1" php
EXPECT='mariadb -e CREATE DATABASE IF NOT EXISTS `mvp_Example_com` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
check "(1) 未設引擎 → mariadb 參數逐字相同" has_line "$EXPECT"
check "(1) 未設引擎 → 不呼叫 createdb/psql" bash -c "! grep -qE '^(createdb|psql|runuser)' '$LOG'"
WEBOPS_DB_ENGINE="" run_case "$S1" php
check "(1b) 空值 → mariadb" has_line "$EXPECT"

# === (2) 只有 mysql → 退回 mysql ===
S2="$WORK/s2"; make_stubs "$S2" mysql
unset WEBOPS_DB_ENGINE
run_case "$S2" php
check "(2) 只有 mysql → 用 mysql" has_line "mysql -e CREATE DATABASE IF NOT EXISTS \`mvp_Example_com\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# === (3) postgresql：不存在 → createdb；已存在 → 不 createdb ===
S3="$WORK/s3"; make_stubs "$S3" psql createdb runuser id getent
export WEBOPS_DB_ENGINE=postgresql
STUB_PG_EXISTS=0 run_case "$S3" laravel
check "(3) PG 庫不存在 → 呼叫 runuser createdb（名稱小寫）" has_line "createdb -E UTF8 -T template0 mvp_example_com"
check "(3) PG 以 postgres 帳號 peer 執行" has_prefix "runuser -u postgres -- createdb"
check "(3) laravel 模式提示 DB_CONNECTION=pgsql" msgs_has DB_CONNECTION=pgsql
STUB_PG_EXISTS=0 run_case "$S3" php
check "(3) php 模式不提 DB_CONNECTION" msgs_lacks DB_CONNECTION=pgsql
STUB_PG_EXISTS=1 run_case "$S3" laravel
check "(3) PG 庫已存在 → 不呼叫 createdb" bash -c "! grep -q '^createdb' '$LOG'"
check "(3) PG 已存在 → 有先查 pg_database" bash -c "grep -q 'pg_database' '$LOG'"
export STUB_PG_EXISTS=0
S3b="$WORK/s3b"; make_stubs "$S3b" createdb runuser id    # 沒有 psql
run_case "$S3b" php
check "(3) 沒有 psql → 提示 apt install postgresql" msgs_has "apt install -y postgresql"
check "(3) 沒有 psql → 不呼叫 createdb" bash -c "! grep -q '^createdb' '$LOG'"

# === (4) 名稱 > 63 → 拒絕 ===
: > "$LOG"; TUI_MSGS=""
LONG="mvp_$(printf 'a%.0s' $(seq 1 70))"
PATH="$S3:$REAL_PATH" db_create "$LONG" php
check "(4) 名稱 >63 → 不呼叫 createdb" bash -c "! grep -q '^createdb' '$LOG'"
check "(4) 名稱 >63 → TUI 說明 63 bytes" msgs_has "63 bytes"
LEN63="mvp_$(printf 'a%.0s' $(seq 1 59))"
: > "$LOG"; PATH="$S3:$REAL_PATH" db_create "$LEN63" php
check "(4b) 剛好 63 → 會建立" bash -c "grep -q '^createdb' '$LOG'"

# === (5) 無效引擎值 → mariadb ===
export WEBOPS_DB_ENGINE=oracle
run_case "$S1" php
check "(5) 無效值 → 走 mariadb" has_line "$EXPECT"
TUI_MSGS=""; db_engine_notices php
check "(5) 無效值 → 印警告" msgs_has WARN:

# === (6) wordpress + postgresql → mariadb ===
export WEBOPS_DB_ENGINE=postgresql
run_case "$S1" wordpress
check "(6) wordpress+postgresql → 走 mariadb" has_line "$EXPECT"
check "(6) wordpress+postgresql → 不呼叫 createdb" bash -c "! grep -q '^createdb' '$LOG'"
TUI_MSGS=""; db_engine_notices wordpress
check "(6) 告知 WordPress 不支援 PostgreSQL" msgs_has "WordPress 不支援 PostgreSQL，已改用 MariaDB"

# === (7) 別名 ===
for a in pgsql postgres PostgreSQL; do
    export WEBOPS_DB_ENGINE="$a"
    check "(7) 別名 $a → postgresql" bash -c "[ \"\$(source '$LIB'; db_engine_for php)\" = postgresql ]"
done
unset WEBOPS_DB_ENGINE
check "(7) mariadb 無 SUMMARY 後綴" bash -c "[ -z \"\$(source '$LIB'; db_summary_suffix mariadb)\" ]"

echo "---- PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
