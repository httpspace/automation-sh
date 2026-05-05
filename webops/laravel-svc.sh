#!/bin/bash
#
# laravel-svc.sh — Supervisor 管理 Laravel queue/scheduler（原生 whiptail TUI）
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
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"

require_root
load_env
apply_webops_defaults

tui_available || error "需要 whiptail（apt install -y whiptail）"
command -v supervisorctl >/dev/null 2>&1 || error "需要 supervisor（apt install -y supervisor）"

USERNAME="www-data"
CONF_DIR="/etc/supervisor/conf.d"
[ -d "$CONF_DIR" ] || error "$CONF_DIR 不存在；supervisor 未正確安裝"

# 自動偵測 APP_PATH（先看 WEBOPS_BASE_DIR，再掃 /home/*/public_html）
detect_app_path() {
    local domain="$1" candidate
    for candidate in "$WEBOPS_BASE_DIR/$domain" /home/*/public_html/"$domain"; do
        [ -e "$candidate" ] || continue
        if [ -d "$candidate/backend" ] && [ -f "$candidate/backend/artisan" ]; then
            echo "$candidate/backend"; return 0
        elif [ -f "$candidate/artisan" ]; then
            echo "$candidate"; return 0
        fi
    done
    return 1
}

# 列出已啟用的 short-name 陣列（從 *-sched.conf 取）
list_enabled_short_names() {
    for f in "$CONF_DIR"/*-sched.conf; do
        [ -e "$f" ] || continue
        basename "$f" -sched.conf
    done
}

# === 主迴圈 ===
while true; do
    ACTION=$(tui_menu "Laravel 服務管理 (queue/sched, user=$USERNAME)" \
        "enable"  "啟用 / 更新服務" \
        "disable" "停用服務" \
        "status"  "狀態查詢（supervisorctl）" \
        "list"    "列出已啟用服務的網域" \
        "view"    "檢視 supervisor 配置" \
        "quit"    "離開") || exit 0

    case "$ACTION" in
        enable)
            DOMAIN=$(tui_input "網域（例如 lab.example.com）") || continue
            [ -z "$DOMAIN" ] && continue

            QC=$(tui_input "Queue worker 數量" "1") || continue
            [ -z "$QC" ] && QC=1
            if ! [[ "$QC" =~ ^[0-9]+$ ]]; then
                tui_msg "Queue 數量必須是數字"; continue
            fi

            SHORT_NAME="${DOMAIN//./-}"

            # 自動偵測 app path
            if APP_PATH=$(detect_app_path "$DOMAIN"); then
                :
            else
                APP_PATH=$(tui_input "未自動找到 $DOMAIN 的 Laravel 部署目錄\n請輸入完整路徑（含 artisan 的目錄）" "") || continue
                [ -z "$APP_PATH" ] && continue
                if [ ! -f "$APP_PATH/artisan" ]; then
                    tui_msg "❌ $APP_PATH/artisan 不存在"; continue
                fi
            fi

            # 確認執行
            tui_yesno "啟用 / 更新 Laravel 服務？\n\n網域: $DOMAIN\nApp:  $APP_PATH\nQueue workers: $QC\nUser: $USERNAME" || continue

            # storage / bootstrap/cache 權限
            chown -R "$USERNAME:$USERNAME" "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
            chmod -R 775 "$APP_PATH/storage" 2>/dev/null || true

            # 寫 supervisor confs
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

            output=$(supervisorctl reread 2>&1; supervisorctl update 2>&1)
            tui_msg "✅ $DOMAIN 服務已啟用\n\nApp: $APP_PATH\nQueue workers: $QC\n\nsupervisorctl 輸出:\n$output"
            ;;

        disable)
            declare -a items=()
            while IFS= read -r short; do
                [ -z "$short" ] && continue
                items+=("$short" "${short//-/.}")
            done < <(list_enabled_short_names)

            if [ "${#items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的 Laravel 服務"; continue
            fi

            SEL=$(tui_menu "選擇要停用的服務" "${items[@]}") || continue
            domain="${SEL//-/.}"

            tui_yesno "確定停用並刪除 $domain 的 queue/sched 配置？" || continue

            supervisorctl stop "$SEL-queue:*" "$SEL-sched" 2>/dev/null || true
            rm -f "$CONF_DIR/$SEL-queue.conf" "$CONF_DIR/$SEL-sched.conf"
            output=$(supervisorctl update 2>&1)
            tui_msg "✅ $domain 已從 supervisor 移除\n\n$output"
            ;;

        status)
            output=$(supervisorctl status 2>&1 | grep -E 'queue|sched' || echo "目前無 queue/sched 服務")
            tui_scroll "supervisorctl 狀態" "$output"
            ;;

        list)
            content=""
            found=0
            while IFS= read -r short; do
                [ -z "$short" ] && continue
                content+="● ${short//-/.}\n"
                found=1
            done < <(list_enabled_short_names)
            [ "$found" = "0" ] && content="（無）"
            tui_scroll "已啟用 Laravel 服務的網域" "$content"
            ;;

        view)
            declare -a items=()
            while IFS= read -r short; do
                [ -z "$short" ] && continue
                items+=("$short" "${short//-/.}")
            done < <(list_enabled_short_names)

            if [ "${#items[@]}" -eq 0 ]; then
                tui_msg "目前無 supervisor 配置"; continue
            fi

            SEL=$(tui_menu "選擇要檢視的服務" "${items[@]}") || continue
            content="--- $SEL-queue.conf ---\n"
            content+="$(cat "$CONF_DIR/$SEL-queue.conf" 2>/dev/null || echo '(無)')\n\n"
            content+="--- $SEL-sched.conf ---\n"
            content+="$(cat "$CONF_DIR/$SEL-sched.conf" 2>/dev/null || echo '(無)')"
            tui_scroll "${SEL//-/.} 配置" "$content"
            ;;

        quit) exit 0 ;;
    esac
done
