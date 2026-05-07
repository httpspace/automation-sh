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

# 掃所有 /home/*/public_html/ 與 WEBOPS_BASE_DIR 下含 artisan 的 Laravel 站
# stdout: 每行一個 domain（或子目錄名），dedup
list_laravel_domains() {
    declare -A seen=()
    local f app_dir domain
    while IFS= read -r f; do
        app_dir="$(dirname "$f")"
        if [[ "$app_dir" =~ /public_html/([^/]+)/backend$ ]]; then
            domain="${BASH_REMATCH[1]}"
        elif [[ "$app_dir" =~ /public_html/([^/]+)$ ]]; then
            domain="${BASH_REMATCH[1]}"
        else
            continue
        fi
        [ -n "${seen[$domain]:-}" ] && continue
        seen[$domain]=1
        echo "$domain"
    done < <(find /home/*/public_html/ -maxdepth 3 -mindepth 2 -type f -name 'artisan' 2>/dev/null)
}

# Picker：列出偵測到的 Laravel 站；附「手動輸入」逃生口
# stdout: 選中的 domain（空字串 = 取消）
pick_laravel_domain() {
    declare -a items=()
    local d
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        items+=("$d" "$d")
    done < <(list_laravel_domains)

    items+=("__manual__" "✏ 手動輸入網域")

    local sel
    if [ "${#items[@]}" -le 2 ]; then
        # 只有 manual 一條 → 直接走手動輸入
        tui_input "未偵測到 Laravel 站點\n請輸入網域" "" || return 1
        return 0
    fi

    sel=$(tui_menu "選擇 Laravel 站點" "${items[@]}") || return 1
    if [ "$sel" = "__manual__" ]; then
        tui_input "手動輸入網域（例如 lab.example.com）" "" || return 1
        return 0
    fi
    echo "$sel"
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
build_enabled_items() {
    declare -ag _enabled_items=()
    while IFS= read -r short; do
        [ -z "$short" ] && continue
        _enabled_items+=("$short" "${short//-/.}")
    done < <(list_enabled_short_names)
}

# === 啟用流程（抽出成函式，讓 preset 路徑能跳過 menu）===
# 用法: run_enable_flow [domain]
#   domain 為空 → picker 模式（list_laravel_domains + 手動輸入逃生口）
#   domain 給值 → 直接用該 domain 跑流程（給 deploy-site 鏈式呼叫用）
run_enable_flow() {
    local DOMAIN="${1:-}"

    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(pick_laravel_domain) || return 0
        [ -z "$DOMAIN" ] && return 0
    fi

    local SHORT_NAME="${DOMAIN//./-}"

    # 偵測既有 conf — 提早問覆蓋與否
    local IS_UPDATE=0
    if [ -f "$CONF_DIR/$SHORT_NAME-queue.conf" ] || [ -f "$CONF_DIR/$SHORT_NAME-sched.conf" ]; then
        tui_yesno "$DOMAIN 服務已存在 — 覆蓋為新參數？\n\n（會先寫新 conf、reread + update，再 restart 讓新參數生效）" || return 0
        IS_UPDATE=1
    fi

    # 自動偵測 app path
    local APP_PATH
    if APP_PATH=$(detect_app_path "$DOMAIN"); then
        :
    else
        APP_PATH=$(tui_input "未自動找到 $DOMAIN 的 Laravel 部署目錄\n請輸入完整路徑（含 artisan 的目錄）" "") || return 0
        [ -z "$APP_PATH" ] && return 0
        if [ ! -f "$APP_PATH/artisan" ]; then
            tui_msg "❌ $APP_PATH/artisan 不存在"; return 0
        fi
    fi

    # === Queue 參數 ===
    local QC TRIES TIMEOUT QUEUE_NAME SCHED_SLEEP
    QC=$(tui_input "Queue worker 數量（numprocs）\n\n  1   一般站\n  3+  高吞吐 / 並行 job" "1") || return 0
    [ -z "$QC" ] && QC=1
    [[ "$QC" =~ ^[0-9]+$ ]] || { tui_msg "Queue 數量必須是數字"; return 0; }

    TRIES=$(tui_input "重試次數（--tries）\n\n  1   MVP / 開發（fail fast 見真 bug）\n  3   production（容忍 transient 失敗）\n  0   無限（不建議）" "1") || return 0
    [ -z "$TRIES" ] && TRIES=1
    [[ "$TRIES" =~ ^[0-9]+$ ]] || { tui_msg "重試次數必須是數字"; return 0; }

    TIMEOUT=$(tui_input "單個 job 超時秒數（--timeout）\n\n  60   一般 API/CRUD job\n  300  匯出、報表類\n  600+ AI 推論、長批次" "60") || return 0
    [ -z "$TIMEOUT" ] && TIMEOUT=60
    [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { tui_msg "超時秒數必須是數字"; return 0; }

    QUEUE_NAME=$(tui_input "Queue 名稱（--queue；多個用逗號優先序，例 high,default）" "default") || return 0
    [ -z "$QUEUE_NAME" ] && QUEUE_NAME="default"

    SCHED_SLEEP=$(tui_input "排程檢查間隔（schedule:work --sleep；秒）

  60  一般 Laravel 排程（預設）
  30  sub-minute 排程（需 Laravel 11+ 且
       routes/console.php 用 ->everyThirtySeconds()）
  10  高頻心跳（CPU 開銷較大；多數情境不建議）

< 60 秒只對有定義 sub-minute 排程的 app 有意義；
   否則 task 仍依各自 cron 表達式照常跑。" "60") || return 0
    [ -z "$SCHED_SLEEP" ] && SCHED_SLEEP=60
    [[ "$SCHED_SLEEP" =~ ^[0-9]+$ ]] || { tui_msg "間隔秒數必須是數字"; return 0; }
    [ "$SCHED_SLEEP" -lt 1 ] && { tui_msg "間隔秒數必須 ≥ 1"; return 0; }

    if [ "$SCHED_SLEEP" -lt 60 ]; then
        tui_yesno "排程間隔 ${SCHED_SLEEP}s < 60s

只在以下兩個都滿足時才有實際效果：
  1. Laravel 11+
  2. routes/console.php 有定義 ->everyThirtySeconds()
     ->everyTenSeconds() 等 sub-minute 排程

不滿足的話 schedule:run 會空轉（多耗 ~200ms × 每 ${SCHED_SLEEP}s
boot Laravel）但不會壞東西。

確定要繼續？" || return 0
    fi

    # 摘要 + 最終確認
    local TRIES_NOTE=""
    [ "$TRIES" = "1" ] && TRIES_NOTE=" (no retry)"
    [ "$TRIES" = "0" ] && TRIES_NOTE=" (unlimited)"

    local SLEEP_NOTE=""
    [ "$SCHED_SLEEP" -lt 60 ] && SLEEP_NOTE=" (sub-minute, 需 Laravel 11+)"

    tui_yesno "確認 ${IS_UPDATE:+更新}${IS_UPDATE:-啟用} Laravel 服務？

網域:           $DOMAIN
App:            $APP_PATH
User:           $USERNAME
Queue workers:  $QC
Tries:          $TRIES${TRIES_NOTE}
Timeout:        ${TIMEOUT}s/job
Queue:          $QUEUE_NAME
排程間隔:       ${SCHED_SLEEP}s${SLEEP_NOTE}" || return 0

    # storage / bootstrap/cache 權限
    chown -R "$USERNAME:$USERNAME" "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
    chmod -R 775 "$APP_PATH/storage" 2>/dev/null || true

    local STOP_WAIT=$((TIMEOUT + 60))

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

    local output
    output=$(supervisorctl reread 2>&1; supervisorctl update 2>&1)

    if [ "$IS_UPDATE" = 1 ]; then
        local restart_out
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
}

# === Preset 模式（給 deploy-site 鏈式呼叫，跑完一次就離開）===
PRESET_DOMAIN="${WEBOPS_PRESET_DOMAIN:-}"
unset WEBOPS_PRESET_DOMAIN
if [ -n "$PRESET_DOMAIN" ]; then
    run_enable_flow "$PRESET_DOMAIN"
    exit 0
fi

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
            run_enable_flow ""
            ;;

        restart)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的 Laravel 服務"; continue
            fi

            # 算個別站數量（每兩個 array 元素是一個 entry）
            N_SITES=$(( ${#_enabled_items[@]} / 2 ))

            # 在最前面插一條「全部重啟」捷徑
            declare -a items_with_all=("__all__" "全部重啟（$N_SITES 站）" "${_enabled_items[@]}")

            SEL=$(tui_menu "選擇要重啟的服務" "${items_with_all[@]}") || continue

            if [ "$SEL" = "__all__" ]; then
                tui_yesno "重啟全部 Laravel 服務（$N_SITES 站的 queue + sched）？\n\n（適合 shared library 升級後一次刷新；不影響其他 supervisor 程式）" || continue
                declare -a all_progs=()
                while IFS= read -r short; do
                    [ -z "$short" ] && continue
                    all_progs+=("$short-queue:*" "$short-sched")
                done < <(list_enabled_short_names)
                output=$(supervisorctl restart "${all_progs[@]}" 2>&1 || true)
                tui_msg "✅ 全部 Laravel 服務已重啟（$N_SITES 站）\n\n$output"
            else
                domain="${SEL//-/.}"
                tui_yesno "重啟 $domain 的 queue + sched？\n\n（適合 git pull / composer install 上新版 code 後執行；\n  worker 會優雅停止當前 job 後重啟）" || continue
                output=$(supervisorctl restart "$SEL-queue:*" "$SEL-sched" 2>&1 || true)
                tui_msg "✅ $domain 已重啟\n\n$output"
            fi
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
