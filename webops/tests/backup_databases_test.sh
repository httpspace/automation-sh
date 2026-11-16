#!/bin/bash
# backup_databases_test.sh — backup_databases.sh 的 stub 測試（不碰真實 DB / 掛載點）
# 用法: bash webops/tests/backup_databases_test.sh
# 做法：用 sed 產生去掉 root 檢查的暫存副本；PATH stub mountpoint/mariadb-dump/pg_dump/runuser/ionice。
# (i) 與 git HEAD 版本比對 mariadb-dump 收到的參數（逐字相同）。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# stub bin
BIN="$WORK/bin"; mkdir -p "$BIN"
mk() { printf '%s\n' "#!/bin/bash" "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
mk mountpoint 'exit 0'
mk ionice     'shift 1; exec "$@"'
mk mariadb-dump 'echo "mariadb-dump $*" >> "$CALLS"; echo "-- fake mariadb dump"'
mk pg_dump      'echo "pg_dump $*" >> "$CALLS"; echo "-- fake pg dump"'
mk runuser      'echo "runuser $*" >> "$CALLS"; shift 3; exec "$@"'
export CALLS

# 產生去掉 root 檢查的副本：make_copy <src-script> <dir>
make_copy() {
    mkdir -p "$2"
    sed 's/"\$EUID" -ne 0/0 -ne 0/' "$1" > "$2/backup_databases.sh"
}
git -C "$REPO" show HEAD:backup_databases.sh > "$WORK/orig_src.sh"
make_copy "$WORK/orig_src.sh"          "$WORK/orig"
make_copy "$REPO/backup_databases.sh"  "$WORK/new"

# 注意：.env 以 export $(grep | xargs) 載入（既有行為），xargs 會吃掉引號，
# 所以測試值一律用單一 token（不含空白）。
# run_case <copy-dir> <env-lines...> → 設定 .env 後執行；回傳腳本 exit code
run_case() {
    local dir="$1"; shift
    local out="$WORK/bk"; rm -rf "$out"; mkdir -p "$out"
    {
        echo "BACKUP_DIR=$out/backups"
        echo "BACKUP_LOG_DIR=$out/logs"
        echo "BACKUP_MOUNT_POINT=$out"
        printf '%s\n' "$@"
    } > "$dir/.env"
    : > "$CALLS"
    PATH="$BIN:$PATH" bash "$dir/backup_databases.sh" > "$WORK/run.out" 2>&1
}
norm() { sed -E 's#--defaults-extra-file=[^ ]+#--defaults-extra-file=<F>#' "$CALLS"; }

# === (i) 只有 BACKUP_DBS：mariadb-dump 參數與 HEAD 逐字相同，且沒呼叫 pg_dump ===
ENVA=(DB_USER=u DB_PASS=p BACKUP_DBS=alpha:t1,t2)
run_case "$WORK/orig" "${ENVA[@]}"; rc_o=$?; norm > "$WORK/o.txt"
run_case "$WORK/new"  "${ENVA[@]}"; rc_n=$?; norm > "$WORK/n.txt"
[ "$rc_o" -eq 0 ] && [ "$rc_n" -eq 0 ] && ok "(i) HEAD 與新版皆 exit 0" || bad "(i) exit code orig=$rc_o new=$rc_n"
if [ -s "$WORK/o.txt" ] && cmp -s "$WORK/o.txt" "$WORK/n.txt"; then ok "(i) mariadb-dump 參數與 HEAD 逐字相同"; else bad "(i) mariadb-dump 參數不同"; diff "$WORK/o.txt" "$WORK/n.txt"; fi
grep -q 'mariadb-dump' "$WORK/n.txt" && [ "$(grep -c '^mariadb-dump' "$WORK/n.txt")" -eq 1 ] && ok "(i) mariadb-dump 呼叫 1 次" || bad "(i) mariadb-dump 次數"
if grep -qE 'pg_dump|runuser' "$CALLS"; then bad "(i) 不應呼叫 pg_dump/runuser"; else ok "(i) 完全沒呼叫 pg_dump/runuser"; fi
ls "$WORK/bk/backups" | grep -q '^pg_' && bad "(i) 不應有 pg_ 檔" || ok "(i) 沒有 pg_ 檔"

# === (ii) 只有 BACKUP_PG_DBS、沒有 DB_USER ===
run_case "$WORK/new" BACKUP_PG_DBS=pgone; rc=$?
[ "$rc" -eq 0 ] && ok "(ii) 無 DB_USER 正常跑 exit 0" || { bad "(ii) exit=$rc"; cat "$WORK/run.out"; }
ls "$WORK/bk/backups" | grep -qx 'pg_pgone_[0-9_]*\.sql\.gz' && ok "(ii) 產生 pg_pgone_*.sql.gz" || bad "(ii) 缺 pg_pgone 檔: $(ls "$WORK/bk/backups")"
grep -q '^pg_dump --no-owner pgone$' "$CALLS" && ok "(ii) pg_dump --no-owner pgone" || bad "(ii) pg_dump 參數: $(cat "$CALLS")"
grep -q '^runuser -u postgres -- pg_dump' "$CALLS" && ok "(ii) 以 runuser -u postgres 執行" || bad "(ii) 未用 runuser"
grep -q 'mariadb-dump' "$CALLS" && bad "(ii) 不應呼叫 mariadb-dump" || ok "(ii) 沒呼叫 mariadb-dump"
run_case "$WORK/new" BACKUP_PG_DBS=pgtwo:public.t1,t2
ls "$WORK/bk/backups" | grep -q '^pg_pgtwo_public.t1-t2_' && ok "(ii) 表名檔名標籤 pg_pgtwo_public.t1-t2_*" || bad "(ii) 缺 pgtwo 檔"
grep -q '^pg_dump --no-owner -t public.t1 -t t2 pgtwo$' "$CALLS" && ok "(ii) 表名原樣傳 -t" || bad "(ii) -t 參數: $(cat "$CALLS")"

# === (ii-b) 兩者並存：兩邊都跑、SUCCESS_COUNT 合計（觸發清理訊息）===
run_case "$WORK/new" DB_USER=u DB_PASS=p "BACKUP_DBS=alpha" "BACKUP_PG_DBS=pgone"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^mariadb-dump' "$CALLS" && grep -q '^pg_dump' "$CALLS" && ok "(ii-b) 兩者並存都執行" || bad "(ii-b)"

# === (ii-c) pg_dump 失敗 / 0 bytes → .bad ===
mk pg_dump 'exit 3'
run_case "$WORK/new" "BACKUP_PG_DBS=pgone"
ls "$WORK/bk/backups" | grep -q '\.bad$' && grep -q 'pg_dump 版本低於 server' "$WORK/run.out" && ok "(ii-c) pg_dump 失敗 → .bad 且 log 提醒版本" || bad "(ii-c) $(ls "$WORK/bk/backups"; tail -3 "$WORK/run.out")"
mk pg_dump 'exit 0'
run_case "$WORK/new" "BACKUP_PG_DBS=pgone"
# gzip 空輸入仍有 header 非 0 bytes，故此情境只驗證成功路徑不產生 .bad
ls "$WORK/bk/backups" | grep -q '\.bad$' && bad "(ii-c) 不應有 .bad" || ok "(ii-c) 成功路徑無 .bad"

# === (iii) 兩者都沒設 → 錯誤退出 ===
run_case "$WORK/new" DB_USER=u DB_PASS=p; rc=$?
[ "$rc" -ne 0 ] && grep -q 'BACKUP_PG_DBS' "$WORK/run.out" && ok "(iii) 兩者皆無 → exit $rc 並提示" || bad "(iii) rc=$rc"
# BACKUP_DBS 有、DB_USER 沒有 → 仍錯誤（行為不變）
run_case "$WORK/new" "BACKUP_DBS=alpha"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'DB_USER' "$WORK/run.out" && ok "(iii) BACKUP_DBS 有但缺 DB_USER → exit $rc" || bad "(iii-b) rc=$rc"

echo "---- PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
