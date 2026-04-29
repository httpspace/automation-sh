#!/bin/bash
#
# backup_databases.sh — 高穩定資料庫備份腳本（讀取 .env 設定）
# 用法: sudo ./backup_databases.sh
#
# 功能：
#   - 以 mariadb-dump --single-transaction 對指定 DB 做不鎖表備份
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
: "${DB_USER:?.env 中缺少 DB_USER}"
: "${DB_PASS:?.env 中缺少 DB_PASS}"
: "${BACKUP_DIR:?.env 中缺少 BACKUP_DIR}"
: "${BACKUP_LOG_DIR:?.env 中缺少 BACKUP_LOG_DIR}"
: "${BACKUP_MOUNT_POINT:?.env 中缺少 BACKUP_MOUNT_POINT}"
: "${BACKUP_DBS:?.env 中缺少 BACKUP_DBS（要備份的資料庫，空格分隔）}"

DB_HOST="${DB_HOST:-localhost}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# 將空格分隔字串轉為陣列
read -r -a DBS <<< "$BACKUP_DBS"

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
        log "⚠  警告：備份已在執行中 (PID: $(cat "$LOCK_FILE"))，跳過本次執行。"
        # 別在 trap 裡誤刪別人的 lock
        trap - EXIT
        trap 'rm -f "$MYSQL_DEFAULTS_FILE" 2>/dev/null || true' EXIT
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
}

# === 5. 資源控制 ===
IONICE="ionice -c3"   # 僅在磁碟閒置時執行
NICE="nice -n19"      # 最低 CPU 優先權

# === 6. 執行備份 ===
check_mount
acquire_lock
create_defaults_file

log "🚀  開始執行資料庫備份任務 ($BACKUP_DIR)..."

for DB in "${DBS[@]}"; do
    TARGET_FILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    log "📦  正在備份資料庫: $DB ..."

    if $NICE $IONICE mariadb-dump \
        --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --hex-blob \
        "$DB" | gzip > "$TARGET_FILE"; then

        if [ -s "$TARGET_FILE" ]; then
            FILE_SIZE=$(du -sh "$TARGET_FILE" | awk '{print $1}')
            log "✅  $DB 備份完成！大小: $FILE_SIZE"
        else
            log "❌  $DB 備份檔案異常 (大小為 0)，已標記為 .bad"
            mv "$TARGET_FILE" "${TARGET_FILE}.bad"
        fi
    else
        log "❌  $DB 備份指令執行失敗！"
        [ -f "$TARGET_FILE" ] && mv "$TARGET_FILE" "${TARGET_FILE}.bad"
    fi
done

# === 7. 清理舊備份 ===
log "🧹  正在清理 ${RETENTION_DAYS} 天前的舊備份..."
$NICE $IONICE find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
$NICE $IONICE find "$BACKUP_DIR" -name "*.sql.gz.bad" -mtime +"$RETENTION_DAYS" -delete

log "🏁  備份任務結束。"
