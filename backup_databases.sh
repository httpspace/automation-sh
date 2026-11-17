#!/bin/bash
#
# backup_databases.sh — 高穩定資料庫備份腳本（讀取 .env 設定）
# 用法: sudo ./backup_databases.sh
#
# 功能：
#   - 以 mariadb-dump --single-transaction 對指定 DB 做不鎖表備份
#   - 選用：BACKUP_PG_DBS 以 postgres 系統帳號（peer 認證）+ pg_dump 備份 PostgreSQL
#   - 寫入指定掛載碟（保護系統碟空間）
#   - 鎖檔避免重複執行、最低 CPU/IO 優先權
#   - 自動清理保留期外的舊備份
#

set -euo pipefail
PATH=/usr/bin:/usr/local/bin:/sbin:/bin:/usr/sbin:$PATH

# === 顏色設定 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# === 檢查 Root 權限 ===
if [ "$EUID" -ne 0 ]; then
    error "請使用 sudo 或 root 權限執行此腳本。"
fi

# === 1. 載入 .env 設定 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    info "偵測到 .env，正在載入設定..."
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    error "找不到 .env 檔案！請先複製 .env.example 為 .env 並填入資訊。"
fi

# === 2. 驗證必要變數 ===
# DB_USER / DB_PASS 只供 MariaDB（BACKUP_DBS）使用；僅備份 PostgreSQL 時不必設
if [ -n "${BACKUP_DBS:-}" ]; then
    : "${DB_USER:?.env 中缺少 DB_USER}"
    : "${DB_PASS:?.env 中缺少 DB_PASS}"
fi
: "${BACKUP_DIR:?.env 中缺少 BACKUP_DIR}"
: "${BACKUP_LOG_DIR:?.env 中缺少 BACKUP_LOG_DIR}"
: "${BACKUP_MOUNT_POINT:?.env 中缺少 BACKUP_MOUNT_POINT}"
if [ -z "${BACKUP_DBS:-}" ] && [ -z "${BACKUP_PG_DBS:-}" ]; then
    error ".env 中缺少 BACKUP_DBS（MariaDB）或 BACKUP_PG_DBS（PostgreSQL）（要備份的資料庫，空格分隔）"
fi

DB_HOST="${DB_HOST:-localhost}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# 將空格分隔字串轉為陣列
# 支援的項目格式：
#   db_name              → 整個資料庫
#   db_name:t1           → 該 DB 的單一資料表
#   db_name:t1,t2,t3     → 該 DB 的多張表（同一份輸出檔）
DB_SPECS=()
read -r -a DB_SPECS <<< "${BACKUP_DBS:-}"
# PostgreSQL 項目語法相同（表名原樣傳給 pg_dump -t，可含 schema 前綴）
PG_SPECS=()
read -r -a PG_SPECS <<< "${BACKUP_PG_DBS:-}"

# === 3. 路徑與檔名 ===
LOCK_FILE="/tmp/backup_databases.lock"
LOG_FILE="$BACKUP_LOG_DIR/backup_databases.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M")

mkdir -p "$BACKUP_DIR" "$BACKUP_LOG_DIR"

# === 4. 工具函數 ===
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }

# 安全傳遞密碼：寫入暫存設定檔，chmod 600，避免出現在 ps
MYSQL_DEFAULTS_FILE=""

cleanup() {
    [ -n "$MYSQL_DEFAULTS_FILE" ] && [ -f "$MYSQL_DEFAULTS_FILE" ] && rm -f "$MYSQL_DEFAULTS_FILE"
    [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ] && rm -f "$LOCK_FILE"
}
trap cleanup EXIT

create_defaults_file() {
    MYSQL_DEFAULTS_FILE=$(mktemp)
    chmod 600 "$MYSQL_DEFAULTS_FILE"
    cat > "$MYSQL_DEFAULTS_FILE" <<EOF
[client]
user=$DB_USER
password=$DB_PASS
host=$DB_HOST
EOF
}

check_mount() {
    if ! mountpoint -q "$BACKUP_MOUNT_POINT"; then
        log "❌  錯誤：掛載點 $BACKUP_MOUNT_POINT 未掛載，為保護系統碟，終止備份。"
        exit 1
    fi
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            log "⚠  警告：備份已在執行中 (PID: $old_pid)，跳過本次執行。"
            # 別在 trap 裡誤刪別人的 lock
            trap - EXIT
            trap 'rm -f "$MYSQL_DEFAULTS_FILE" 2>/dev/null || true' EXIT
            exit 1
        fi
        log "⚠  清除殘留 lock (PID: ${old_pid:-空})"
    fi
    echo $$ > "$LOCK_FILE"
}

# === 5. 資源控制 ===
IONICE="ionice -c3"   # 僅在磁碟閒置時執行
NICE="nice -n19"      # 最低 CPU 優先權

# === 6. 執行備份 ===
check_mount
acquire_lock
if [ -n "${BACKUP_DBS:-}" ]; then
    create_defaults_file
fi

log "🚀  開始執行資料庫備份任務 ($BACKUP_DIR)..."

MARIA_OK=0   # MariaDB 成功筆數（只決定是否清 MariaDB 舊檔）
PG_OK=0      # PostgreSQL 成功筆數（只決定是否清 pg_ 舊檔）

# ${arr[@]+...} 寫法：BACKUP_DBS 為空（僅備份 PG）時，舊版 bash + set -u 也不會報 unbound variable
for SPEC in ${DB_SPECS[@]+"${DB_SPECS[@]}"}; do
    # 解析 db 或 db:tables 語法
    if [[ "$SPEC" == *:* ]]; then
        DB="${SPEC%%:*}"
        IFS=',' read -r -a TABLES <<< "${SPEC#*:}"
        # 用 - 連接表名作為檔名標籤（例：voxy_users-lessons_TS.sql.gz）
        TABLE_LABEL=$(IFS='-'; echo "${TABLES[*]}")
        TARGET_FILE="${BACKUP_DIR}/${DB}_${TABLE_LABEL}_${TIMESTAMP}.sql.gz"
        DUMP_ARGS=("$DB" "${TABLES[@]}")
        log "📦  正在備份: $DB → tables: ${TABLES[*]}"
    else
        DB="$SPEC"
        TARGET_FILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
        DUMP_ARGS=("$DB")
        log "📦  正在備份資料庫: $DB ..."
    fi

    if $NICE $IONICE mariadb-dump \
        --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --hex-blob \
        "${DUMP_ARGS[@]}" | gzip > "$TARGET_FILE"; then

        if [ -s "$TARGET_FILE" ]; then
            FILE_SIZE=$(du -sh "$TARGET_FILE" | awk '{print $1}')
            log "✅  $DB 備份完成！大小: $FILE_SIZE"
            MARIA_OK=$((MARIA_OK + 1))
        else
            log "❌  $DB 備份檔案異常 (大小為 0)，已標記為 .bad"
            mv "$TARGET_FILE" "${TARGET_FILE}.bad"
        fi
    else
        log "❌  $DB 備份指令執行失敗！"
        [ -f "$TARGET_FILE" ] && mv "$TARGET_FILE" "${TARGET_FILE}.bad"
    fi
done

# === 6b. PostgreSQL 備份（BACKUP_PG_DBS；peer 認證，不用密碼檔）===
for SPEC in ${PG_SPECS[@]+"${PG_SPECS[@]}"}; do
    PG_ARGS=(--no-owner)
    if [[ "$SPEC" == *:* ]]; then
        DB="${SPEC%%:*}"
        IFS=',' read -r -a TABLES <<< "${SPEC#*:}"
        TABLE_LABEL=$(IFS='-'; echo "${TABLES[*]}")
        TARGET_FILE="${BACKUP_DIR}/pg_${DB}_${TABLE_LABEL}_${TIMESTAMP}.sql.gz"
        for T in "${TABLES[@]}"; do PG_ARGS+=(-t "$T"); done
        log "📦  正在備份 PostgreSQL: $DB → tables: ${TABLES[*]}"
    else
        DB="$SPEC"
        TARGET_FILE="${BACKUP_DIR}/pg_${DB}_${TIMESTAMP}.sql.gz"
        log "📦  正在備份 PostgreSQL 資料庫: $DB ..."
    fi

    # 重導由 root 處理（寫檔權限無虞）；pg_dump 由 postgres 帳號以 peer 認證執行
    if $NICE $IONICE runuser -u postgres -- pg_dump "${PG_ARGS[@]}" "$DB" | gzip > "$TARGET_FILE"; then

        if [ -s "$TARGET_FILE" ]; then
            FILE_SIZE=$(du -sh "$TARGET_FILE" | awk '{print $1}')
            log "✅  PostgreSQL $DB 備份完成！大小: $FILE_SIZE"
            PG_OK=$((PG_OK + 1))
        else
            log "❌  PostgreSQL $DB 備份檔案異常 (大小為 0)，已標記為 .bad"
            mv "$TARGET_FILE" "${TARGET_FILE}.bad"
        fi
    else
        log "❌  PostgreSQL $DB 備份指令執行失敗！（可能原因：pg_dump 版本低於 server、postgres 帳號不存在、DB 不存在）"
        [ -f "$TARGET_FILE" ] && mv "$TARGET_FILE" "${TARGET_FILE}.bad"
    fi
done

# === 7. 清理舊備份 ===
# MariaDB 與 PG 分開判斷：某一邊全失敗時，不清該邊舊檔（避免唯一的好備份被輪替掉）
# MariaDB 檔以「非 pg_ 前綴」界定；PG 檔為 pg_ 前綴
if [ "$MARIA_OK" -gt 0 ] || [ "$PG_OK" -gt 0 ]; then
    log "🧹  正在清理 ${RETENTION_DAYS} 天前的舊備份..."
    if [ "$MARIA_OK" -gt 0 ]; then
        $NICE $IONICE find "$BACKUP_DIR" -name "*.sql.gz" ! -name "pg_*" -mtime +"$RETENTION_DAYS" -delete
        $NICE $IONICE find "$BACKUP_DIR" -name "*.sql.gz.bad" ! -name "pg_*" -mtime +"$RETENTION_DAYS" -delete
    elif [ -n "${BACKUP_DBS:-}" ]; then
        log "⚠  MariaDB 本輪無成功備份，跳過 MariaDB 舊檔清理"
    fi
    if [ "$PG_OK" -gt 0 ]; then
        $NICE $IONICE find "$BACKUP_DIR" -name "pg_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
        $NICE $IONICE find "$BACKUP_DIR" -name "pg_*.sql.gz.bad" -mtime +"$RETENTION_DAYS" -delete
    elif [ -n "${BACKUP_PG_DBS:-}" ]; then
        log "⚠  PostgreSQL 本輪無成功備份，跳過 pg_ 舊檔清理"
    fi
else
    log "⚠  本輪無成功備份，跳過清理"
fi

log "🏁  備份任務結束。"
