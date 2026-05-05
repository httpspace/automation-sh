#!/bin/bash
#
# laravel-svc.sh — Supervisor 管理 Laravel queue/scheduler
# 用法: sudo laravel-svc
#
# 設定：
#   WEBOPS_BASE_DIR   站點根目錄（預設 /home/svc-app/public_html）
#   USERNAME 在此固定為 www-data（artisan 慣例；不從 .env 取）
#
# 與舊版相容：產生的 supervisor conf 命名格式 <short-name>-queue.conf / <short-name>-sched.conf
# 與原 easy/laravel-service.sh 一致；新版可繼續操作舊版建立的 conf。
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

require_root
load_env
apply_webops_defaults

# 檢查 supervisor 已安裝
command -v supervisorctl >/dev/null 2>&1 || error "需要 supervisor（apt install -y supervisor）"

USERNAME="www-data"
CONF_DIR="/etc/supervisor/conf.d"
[ -d "$CONF_DIR" ] || error "$CONF_DIR 不存在；supervisor 未正確安裝"

while true; do
    clear
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${GREEN}        🚀  Laravel 服務管理 (queue/sched, user=$USERNAME)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo "1) 啟用服務（建立 / 更新 supervisor conf）"
    echo "2) 停用服務（刪除 supervisor conf）"
    echo "3) 狀態查詢"
    echo "4) 列出已建立服務的網域"
    echo "5) 檢視配置"
    echo "q) 離開"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    read -rp "選擇: " ACTION

    case "$ACTION" in
        1)
            read -rp "網域: " DOMAIN
            [ -z "$DOMAIN" ] && continue
            read -rp "Queue 數量 (預設 1): " QC
            QC=${QC:-1}
            SHORT_NAME="${DOMAIN//./-}"

            # 自動偵測：先看預設 BASE_DIR，再掃 /home/*/public_html/<domain>
            APP_PATH=""
            for candidate in "$WEBOPS_BASE_DIR/$DOMAIN" /home/*/public_html/"$DOMAIN"; do
                [ -e "$candidate" ] || continue
                if [ -d "$candidate/backend" ] && [ -f "$candidate/backend/artisan" ]; then
                    APP_PATH="$candidate/backend"
                    break
                elif [ -f "$candidate/artisan" ]; then
                    APP_PATH="$candidate"
                    break
                fi
            done

            if [ -z "$APP_PATH" ]; then
                warn "未自動找到 $DOMAIN 的 Laravel 部署目錄"
                read -rp "請輸入 Laravel app 完整路徑（含 artisan 的目錄）: " APP_PATH
                [ -z "$APP_PATH" ] && continue
                if [ ! -f "$APP_PATH/artisan" ]; then
                    warn "$APP_PATH/artisan 不存在"
                    sleep 2; continue
                fi
            fi
            info "Laravel app 路徑: $APP_PATH"

            info "確認 storage / bootstrap/cache 寫入權限..."
            chown -R "$USERNAME:$USERNAME" "$APP_PATH/storage" "$APP_PATH/bootstrap/cache"
            chmod -R 775 "$APP_PATH/storage"

            info "產生 supervisor 配置..."
            cat > "$CONF_DIR/$SHORT_NAME-queue.conf" <<EOP
[program:$SHORT_NAME-queue]
directory=$APP_PATH
command=php artisan queue:work --sleep=3 --tries=3 --max-time=3600
user=$USERNAME
autostart=true
autorestart=true
numprocs=$QC
process_name=%(program_name)s_%(process_num)02d
redirect_stderr=true
stdout_logfile=$APP_PATH/storage/logs/worker.log
stopwaitsecs=3600
EOP

            cat > "$CONF_DIR/$SHORT_NAME-sched.conf" <<EOP
[program:$SHORT_NAME-sched]
directory=$APP_PATH
command=php artisan schedule:work
user=$USERNAME
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$APP_PATH/storage/logs/scheduler.log
EOP

            supervisorctl reread >/dev/null
            supervisorctl update
            info "✅ $DOMAIN 服務已啟用（user=$USERNAME）"
            sleep 1
            ;;

        2)
            read -rp "網域: " DOMAIN
            [ -z "$DOMAIN" ] && continue
            SHORT_NAME="${DOMAIN//./-}"
            warn "停止並移除 $DOMAIN supervisor 服務..."
            supervisorctl stop "$SHORT_NAME-queue:*" "$SHORT_NAME-sched" 2>/dev/null || true
            rm -f "$CONF_DIR/$SHORT_NAME-queue.conf" "$CONF_DIR/$SHORT_NAME-sched.conf"
            supervisorctl update
            info "✅ $DOMAIN 已從 supervisor 移除"
            sleep 1
            ;;

        3)
            echo -e "\n${BLUE}[狀態查詢]${NC}"
            supervisorctl status | grep -E "queue|sched" || echo "目前無 queue/sched 服務"
            echo -e "\n${YELLOW}按任意鍵返回...${NC}"
            read -rn 1
            ;;

        4)
            echo -e "\n${BLUE}[已建立 supervisor 服務的網域]${NC}"
            found=0
            for f in "$CONF_DIR"/*-sched.conf; do
                [ -e "$f" ] || continue
                name=$(basename "$f" -sched.conf)
                echo -e " ● ${GREEN}${name//-/.}${NC}"
                found=1
            done
            [ "$found" = "0" ] && echo "（無）"
            echo -e "\n${YELLOW}按任意鍵返回...${NC}"
            read -rn 1
            ;;

        5)
            read -rp "輸入網域: " TARGET_IN
            [ -z "$TARGET_IN" ] && continue
            TARGET="${TARGET_IN//./-}"
            echo -e "\n${BLUE}[$TARGET_IN 配置內容]${NC}"
            if [ -f "$CONF_DIR/$TARGET-sched.conf" ]; then
                echo -e "${YELLOW}--- Queue ---${NC}"
                cat "$CONF_DIR/$TARGET-queue.conf" 2>/dev/null || echo "(無 queue conf)"
                echo -e "\n${YELLOW}--- Schedule ---${NC}"
                cat "$CONF_DIR/$TARGET-sched.conf"
            else
                warn "找不到 $TARGET_IN 的 supervisor 配置"
            fi
            echo -e "\n${YELLOW}按任意鍵返回...${NC}"
            read -rn 1
            ;;

        q) exit 0 ;;
        *) warn "無效輸入"; sleep 0.5 ;;
    esac
done
