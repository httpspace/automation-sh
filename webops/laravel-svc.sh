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
# 與原 easy/laravel-service.sh 一致；新版可繼續操作舊版建立的 conf
# （restart / disable / view / logs 都支援舊 conf）。
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
WEBOPS_TUI_TITLE="webops › 排程 + Queue"
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

# 從 supervisor conf 解出 directory= 後面的路徑
get_app_path_from_conf() {
    local conf="$1"
    grep -m1 '^directory=' "$conf" 2>/dev/null | cut -d= -f2-
}

# 建立「選一個已啟用服務」的 menu items array（給多個 case 重用）
# 用法: pick_enabled_service_menu_into items_array_name
build_enabled_items() {
    declare -ag _enabled_items=()
    while IFS= read -r short; do
        [ -z "$short" ] && continue
        _enabled_items+=("$short" "${short//-/.}")
    done < <(list_enabled_short_names)
}

# === 主迴圈 ===
while true; do
    ACTION=$(tui_menu "Laravel 服務管理 (queue/sched, user=$USERNAME)" \
        "enable"  "啟用 / 更新服務" \
        "restart" "重啟服務（reload code 後常用）" \
        "status"  "狀態查詢（supervisorctl）" \
        "logs"    "檢視 worker / scheduler logs" \
        "list"    "列出已啟用服務的網域" \
        "view"    "檢視 supervisor 配置" \
        "disable" "停用服務" \
        "quit"    "離開") || exit 0

    case "$ACTION" in
        enable)
            DOMAIN=$(tui_input "網域（例如 lab.example.com）") || continue
            [ -z "$DOMAIN" ] && continue

            SHORT_NAME="${DOMAIN//./-}"

            # 偵測既有 conf — 提早問覆蓋與否，避免使用者白填一堆參數
            IS_UPDATE=0
            if [ -f "$CONF_DIR/$SHORT_NAME-queue.conf" ] || [ -f "$CONF_DIR/$SHORT_NAME-sched.conf" ]; then
                tui_yesno "$DOMAIN 服務已存在 — 覆蓋為新參數？\n\n（會先寫新 conf、reread + update，再 restart 讓新參數生效）" || continue
                IS_UPDATE=1
            fi

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

            # === Queue 參數（4 個 prompt）===
            QC=$(tui_input "Queue worker 數量（numprocs）\n\n  1   一般站\n  3+  高吞吐 / 並行 job" "1") || continue
            [ -z "$QC" ] && QC=1
            [[ "$QC" =~ ^[0-9]+$ ]] || { tui_msg "Queue 數量必須是數字"; continue; }

            TRIES=$(tui_input "重試次數（--tries）\n\n  1   MVP / 開發（fail fast 見真 bug）\n  3   production（容忍 transient 失敗）\n  0   無限（不建議）" "1") || continue
            [ -z "$TRIES" ] && TRIES=1
            [[ "$TRIES" =~ ^[0-9]+$ ]] || { tui_msg "重試次數必須是數字"; continue; }

            TIMEOUT=$(tui_input "單個 job 超時秒數（--timeout）\n\n  60   一般 API/CRUD job\n  300  匯出、報表類\n  600+ AI 推論、長批次" "60") || continue
            [ -z "$TIMEOUT" ] && TIMEOUT=60
            [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { tui_msg "超時秒數必須是數字"; continue; }

            QUEUE_NAME=$(tui_input "Queue 名稱（--queue；多個用逗號優先序，例 high,default）" "default") || continue
            [ -z "$QUEUE_NAME" ] && QUEUE_NAME="default"

            SCHED_SLEEP=$(tui_input "排程檢查間隔（schedule:work --sleep；秒）

  60  一般 Laravel 排程（預設）
  30  sub-minute 排程（需 Laravel 11+ 且
       routes/console.php 用 ->everyThirtySeconds()）
  10  高頻心跳（CPU 開銷較大；多數情境不建議）

< 60 秒只對有定義 sub-minute 排程的 app 有意義；
   否則 task 仍依各自 cron 表達式照常跑。" "60") || continue
            [ -z "$SCHED_SLEEP" ] && SCHED_SLEEP=60
            [[ "$SCHED_SLEEP" =~ ^[0-9]+$ ]] || { tui_msg "間隔秒數必須是數字"; continue; }
            [ "$SCHED_SLEEP" -lt 1 ] && { tui_msg "間隔秒數必須 ≥ 1"; continue; }

            if [ "$SCHED_SLEEP" -lt 60 ]; then
                tui_yesno "排程間隔 ${SCHED_SLEEP}s < 60s

只在以下兩個都滿足時才有實際效果：
  1. Laravel 11+
  2. routes/console.php 有定義 ->everyThirtySeconds()
     ->everyTenSeconds() 等 sub-minute 排程

不滿足的話 schedule:run 會空轉（多耗 ~200ms × 每 ${SCHED_SLEEP}s
boot Laravel）但不會壞東西。

確定要繼續？" || continue
            fi

            # 摘要 + 最終確認
            TRIES_NOTE=""
            [ "$TRIES" = "1" ] && TRIES_NOTE=" (no retry)"
            [ "$TRIES" = "0" ] && TRIES_NOTE=" (unlimited)"

            SLEEP_NOTE=""
            [ "$SCHED_SLEEP" -lt 60 ] && SLEEP_NOTE=" (sub-minute, 需 Laravel 11+)"

            tui_yesno "確認 ${IS_UPDATE:+更新}${IS_UPDATE:-啟用} Laravel 服務？

網域:           $DOMAIN
App:            $APP_PATH
User:           $USERNAME
Queue workers:  $QC
Tries:          $TRIES${TRIES_NOTE}
Timeout:        ${TIMEOUT}s/job
Queue:          $QUEUE_NAME
排程間隔:       ${SCHED_SLEEP}s${SLEEP_NOTE}" || continue

            # storage / bootstrap/cache 權限
            chown -R "$USERNAME:$USERNAME" "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
            chmod -R 775 "$APP_PATH/storage" 2>/dev/null || true

            # stopwaitsecs 給 timeout + 60s 緩衝（讓 in-flight job 跑完才硬 kill）
            STOP_WAIT=$((TIMEOUT + 60))

            # 寫 supervisor confs
            cat > "$CONF_DIR/$SHORT_NAME-queue.conf" <<EOP
[program:$SHORT_NAME-queue]
directory=$APP_PATH
command=php artisan queue:work --queue=$QUEUE_NAME --tries=$TRIES --timeout=$TIMEOUT --sleep=3 --max-time=3600
user=$USERNAME
autostart=true
autorestart=true
numprocs=$QC
process_name=%(program_name)s_%(process_num)02d
redirect_stderr=true
stdout_logfile=$APP_PATH/storage/logs/worker.log
stopwaitsecs=$STOP_WAIT
EOP

            cat > "$CONF_DIR/$SHORT_NAME-sched.conf" <<EOP
[program:$SHORT_NAME-sched]
directory=$APP_PATH
command=php artisan schedule:work --sleep=$SCHED_SLEEP
user=$USERNAME
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$APP_PATH/storage/logs/scheduler.log
EOP

            output=$(supervisorctl reread 2>&1; supervisorctl update 2>&1)

            # 更新時 restart 讓新參數生效（reread+update 對既有 program 不會自動重啟）
            if [ "$IS_UPDATE" = 1 ]; then
                restart_out=$(supervisorctl restart "$SHORT_NAME-queue:*" "$SHORT_NAME-sched" 2>&1 || true)
                output+=$'\n\n--- restart ---\n'"$restart_out"
            fi

            tui_msg "✅ $DOMAIN 服務已${IS_UPDATE:+更新}${IS_UPDATE:-啟用}

App:            $APP_PATH
Queue workers:  $QC
Tries:          $TRIES${TRIES_NOTE}
Timeout:        ${TIMEOUT}s/job
Queue:          $QUEUE_NAME
排程間隔:       ${SCHED_SLEEP}s${SLEEP_NOTE}

supervisorctl 輸出:
$output"
            ;;

        restart)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的 Laravel 服務"; continue
            fi

            SEL=$(tui_menu "選擇要重啟的服務" "${_enabled_items[@]}") || continue
            domain="${SEL//-/.}"

            tui_yesno "重啟 $domain 的 queue + sched？\n\n（適合 git pull / composer install 上新版 code 後執行；\n  worker 會優雅停止當前 job 後重啟）" || continue

            output=$(supervisorctl restart "$SEL-queue:*" "$SEL-sched" 2>&1 || true)
            tui_msg "✅ $domain 已重啟\n\n$output"
            ;;

        status)
            output=$(supervisorctl status 2>&1 | grep -E 'queue|sched' || echo "目前無 queue/sched 服務")
            tui_scroll "supervisorctl 狀態" "$output"
            ;;

        logs)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的服務"; continue
            fi

            SEL=$(tui_menu "選擇要檢視 logs 的服務" "${_enabled_items[@]}") || continue
            domain="${SEL//-/.}"

            LOG_TYPE=$(tui_menu "$domain — 選擇要看的 log" \
                "queue" "queue worker.log（最後 200 行）" \
                "sched" "scheduler.log（最後 200 行）" \
                "both"  "兩者合併（各 100 行）") || continue

            APP_PATH=$(get_app_path_from_conf "$CONF_DIR/$SEL-queue.conf")
            if [ -z "$APP_PATH" ]; then
                # fallback：如果 queue conf 沒有，試 sched
                APP_PATH=$(get_app_path_from_conf "$CONF_DIR/$SEL-sched.conf")
            fi
            if [ -z "$APP_PATH" ]; then
                tui_msg "❌ 找不到 $SEL 的 directory 設定"; continue
            fi

            QLOG="$APP_PATH/storage/logs/worker.log"
            SLOG="$APP_PATH/storage/logs/scheduler.log"

            case "$LOG_TYPE" in
                queue)
                    if [ -f "$QLOG" ]; then
                        content=$(tail -n 200 "$QLOG" 2>&1 || echo "(讀取失敗)")
                    else
                        content="(尚無 $QLOG — 服務剛啟用 / 沒寫過 log)"
                    fi
                    tui_scroll "$domain — worker.log (last 200)" "$content"
                    ;;
                sched)
                    if [ -f "$SLOG" ]; then
                        content=$(tail -n 200 "$SLOG" 2>&1 || echo "(讀取失敗)")
                    else
                        content="(尚無 $SLOG)"
                    fi
                    tui_scroll "$domain — scheduler.log (last 200)" "$content"
                    ;;
                both)
                    content="--- worker.log (last 100) ---"$'\n'
                    if [ -f "$QLOG" ]; then
                        content+="$(tail -n 100 "$QLOG" 2>&1 || echo '(讀取失敗)')"
                    else
                        content+="(尚無 $QLOG)"
                    fi
                    content+=$'\n\n''--- scheduler.log (last 100) ---'$'\n'
                    if [ -f "$SLOG" ]; then
                        content+="$(tail -n 100 "$SLOG" 2>&1 || echo '(讀取失敗)')"
                    else
                        content+="(尚無 $SLOG)"
                    fi
                    tui_scroll "$domain — logs" "$content"
                    ;;
            esac
            ;;

        list)
            content=""
            found=0
            while IFS= read -r short; do
                [ -z "$short" ] && continue
                content+="● ${short//-/.}"$'\n'
                found=1
            done < <(list_enabled_short_names)
            [ "$found" = "0" ] && content="（無）"
            tui_scroll "已啟用 Laravel 服務的網域" "$content"
            ;;

        view)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無 supervisor 配置"; continue
            fi

            SEL=$(tui_menu "選擇要檢視的服務" "${_enabled_items[@]}") || continue
            content="--- $SEL-queue.conf ---"$'\n'
            content+="$(cat "$CONF_DIR/$SEL-queue.conf" 2>/dev/null || echo '(無)')"
            content+=$'\n\n''--- '"$SEL"'-sched.conf ---'$'\n'
            content+="$(cat "$CONF_DIR/$SEL-sched.conf" 2>/dev/null || echo '(無)')"
            tui_scroll "${SEL//-/.} 配置" "$content"
            ;;

        disable)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的 Laravel 服務"; continue
            fi

            SEL=$(tui_menu "選擇要停用的服務" "${_enabled_items[@]}") || continue
            domain="${SEL//-/.}"

            tui_yesno "確定停用並刪除 $domain 的 queue/sched 配置？" || continue

            supervisorctl stop "$SEL-queue:*" "$SEL-sched" 2>/dev/null || true
            rm -f "$CONF_DIR/$SEL-queue.conf" "$CONF_DIR/$SEL-sched.conf"
            output=$(supervisorctl update 2>&1)
            tui_msg "✅ $domain 已從 supervisor 移除\n\n$output"
            ;;

        quit) exit 0 ;;
    esac
done
