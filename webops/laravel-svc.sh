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
WEBOPS_TUI_TITLE="webops › 排程 + Queue + Reverb"
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

    sel=$(tui_pick_filtered "選擇 Laravel 站點" "${items[@]}") || return 1
    if [ "$sel" = "__manual__" ]; then
        tui_input "手動輸入網域（例如 lab.example.com）" "" || return 1
        return 0
    fi
    echo "$sel"
}

# queue / sched / reverb conf 是否存在（獨立管理後三者可各自缺席）
has_queue_conf() { [ -f "$CONF_DIR/$1-queue.conf" ]; }
has_sched_conf() { [ -f "$CONF_DIR/$1-sched.conf" ]; }
has_reverb_conf() { [ -f "$CONF_DIR/$1-reverb.conf" ]; }

# 列出已啟用的 short-name（queue/sched/reverb 任一存在即列入，dedup + 排序）
list_enabled_short_names() {
    local f
    for f in "$CONF_DIR"/*-queue.conf "$CONF_DIR"/*-sched.conf "$CONF_DIR"/*-reverb.conf; do
        [ -e "$f" ] || continue
        f=$(basename "$f")
        f="${f%-queue.conf}"
        f="${f%-sched.conf}"
        f="${f%-reverb.conf}"
        echo "$f"
    done | sort -u
}

# scope 代碼（單一 queue/sched/reverb，或用 + 串接的組合，例如 queue+sched+reverb）
# → 顯示文字
scope_label() {
    local scope="$1" out="" comp
    local -a parts
    IFS='+' read -ra parts <<< "$scope"
    if [ "${#parts[@]}" -eq 1 ]; then
        case "${parts[0]}" in
            queue)  echo "只 queue" ;;
            sched)  echo "只排程" ;;
            reverb) echo "只 reverb" ;;
        esac
        return 0
    fi
    for comp in "${parts[@]}"; do
        case "$comp" in
            queue)  out="${out:+$out + }queue" ;;
            sched)  out="${out:+$out + }排程" ;;
            reverb) out="${out:+$out + }reverb" ;;
        esac
    done
    echo "$out"
}

# 依站點現有 conf 動態組操作範圍選單；只剩單一服務時直接回傳該範圍不彈窗
# stdout: 單一 tag（queue/sched/reverb）或 + 串接的組合（取消或無服務 return 1）
pick_scope() {
    local prompt="$1" short="$2"
    local -a existing=()
    has_queue_conf "$short" && existing+=("queue")
    has_sched_conf "$short" && existing+=("sched")
    has_reverb_conf "$short" && existing+=("reverb")

    local n="${#existing[@]}"
    if [ "$n" -eq 0 ]; then
        return 1
    elif [ "$n" -eq 1 ]; then
        echo "${existing[0]}"
        return 0
    fi

    local all_scope="" comp
    for comp in "${existing[@]}"; do
        all_scope="${all_scope:+$all_scope+}$comp"
    done

    local -a items=("all" "全部（$(scope_label "$all_scope")）")
    for comp in "${existing[@]}"; do
        items+=("$comp" "$(scope_label "$comp")")
    done

    local sel
    sel=$(tui_menu "$prompt" "${items[@]}") || return 1
    if [ "$sel" = "all" ]; then
        echo "$all_scope"
    else
        echo "$sel"
    fi
}

# 從 supervisor conf 解出 directory= 後面的路徑
get_app_path_from_conf() {
    local conf="$1"
    grep -m1 '^directory=' "$conf" 2>/dev/null | cut -d= -f2-
}

# 建立「選一個已啟用服務」的 menu items array（給多個 case 重用）
# label 附註該站實際啟用的服務，獨立管理後一眼可辨 queue-only / sched-only
build_enabled_items() {
    declare -ag _enabled_items=()
    local short svc
    while IFS= read -r short; do
        [ -z "$short" ] && continue
        svc=""
        has_queue_conf "$short" && svc="queue"
        has_sched_conf "$short" && svc="${svc:+$svc+}排程"
        has_reverb_conf "$short" && svc="${svc:+$svc+}reverb"
        _enabled_items+=("$short" "${short//-/.}（$svc）")
    done < <(list_enabled_short_names)
}

# 健康總覽：每網域一行（queue x/y + sched 狀態 + ✓/⚠/✗ 標記），頂端摘要列出異常站
# stdout: 可直接丟給 tui_scroll 的多行文字
render_status_overview() {
    local sup
    # supervisorctl 在有停止程式時回非零碼 → 必須 || true，否則 set -e 會中止
    sup=$(supervisorctl status 2>&1 || true)

    local -a shorts=()
    local short
    while IFS= read -r short; do
        [ -z "$short" ] && continue
        shorts+=("$short")
    done < <(list_enabled_short_names | sort)

    if [ "${#shorts[@]}" -eq 0 ]; then
        printf '目前無 queue/sched 服務'
        return 0
    fi

    local total="${#shorts[@]}" green=0
    local -a problems=()
    local body="" domain qtotal qrun mark qstate q_field s_field r_field exist_cnt down_cnt
    for short in "${shorts[@]}"; do
        domain="${short//-/.}"
        exist_cnt=0; down_cnt=0

        # queue 以 process_name 展開為 <short>-queue:<short>-queue_NN，每隻 proc 一行
        if has_queue_conf "$short"; then
            exist_cnt=$(( exist_cnt + 1 ))
            qtotal=$(printf '%s\n' "$sup" | grep -cE "^${short}-queue:" || true)
            qrun=$(printf '%s\n' "$sup" | grep -E "^${short}-queue:" | grep -c 'RUNNING' || true)
            if [ "$qtotal" -gt 0 ] && [ "$qrun" -eq "$qtotal" ]; then
                qstate="RUNNING"
            else
                qstate="STOPPED"; down_cnt=$(( down_cnt + 1 ))
            fi
            q_field="$qrun/$qtotal $qstate"
        else
            q_field="—"   # 未啟用 ≠ 異常
        fi

        # sched 單 proc，顯示為 <short>-sched<空白>STATE
        if has_sched_conf "$short"; then
            exist_cnt=$(( exist_cnt + 1 ))
            if printf '%s\n' "$sup" | grep -qE "^${short}-sched[[:space:]].*RUNNING"; then
                s_field="RUNNING"
            else
                s_field="STOPPED"; down_cnt=$(( down_cnt + 1 ))
            fi
        else
            s_field="—"
        fi

        # reverb 單 proc，顯示為 <short>-reverb<空白>STATE
        if has_reverb_conf "$short"; then
            exist_cnt=$(( exist_cnt + 1 ))
            if printf '%s\n' "$sup" | grep -qE "^${short}-reverb[[:space:]].*RUNNING"; then
                r_field="RUNNING"
            else
                r_field="STOPPED"; down_cnt=$(( down_cnt + 1 ))
            fi
        else
            r_field="—"
        fi

        # 健康標記只看實際存在的服務；未啟用的不計入異常
        if [ "$down_cnt" -eq 0 ]; then
            mark="✓"; green=$(( green + 1 ))
        elif [ "$down_cnt" -eq "$exist_cnt" ]; then
            mark="✗"; problems+=("$domain")
        else
            mark="⚠"; problems+=("$domain")
        fi

        body+="$(printf '%s %-30s queue %-12s sched %-10s reverb %s' "$mark" "$domain" "$q_field" "$s_field" "$r_field")"
        body+=$'\n'
    done

    local header="共 $total 站 ｜ ✓ 全綠 $green"
    if [ "${#problems[@]}" -gt 0 ]; then
        local problems_str="" p
        for p in "${problems[@]}"; do
            [ -n "$problems_str" ] && problems_str+="、"
            problems_str+="$p"
        done
        header+=" ｜ ⚠ 異常 ${#problems[@]}：$problems_str"
    fi

    printf '%s\n\n%s' "$header" "$body"
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

    # 範圍：本次要啟用/更新哪些服務（多選；預設勾 queue+排程，Reverb 預設不勾＝維持舊行為）
    local CHECKLIST_RAW WANT_QUEUE=0 WANT_SCHED=0 WANT_REVERB=0
    CHECKLIST_RAW=$(tui_checklist "$DOMAIN — 要啟用哪些服務？" \
        "queue"  "Queue worker（queue:work）" "ON" \
        "sched"  "排程（schedule:work）" "ON" \
        "reverb" "Reverb（WebSocket；需先裝 laravel/reverb）" "OFF") || return 0

    # tui_checklist 輸出是帶雙引號、空白分隔的 tag 串（如 "queue" "sched"）
    CHECKLIST_RAW="${CHECKLIST_RAW//\"/}"
    local tag
    for tag in $CHECKLIST_RAW; do
        case "$tag" in
            queue)  WANT_QUEUE=1 ;;
            sched)  WANT_SCHED=1 ;;
            reverb) WANT_REVERB=1 ;;
        esac
    done

    if [ "$WANT_QUEUE" = 0 ] && [ "$WANT_SCHED" = 0 ] && [ "$WANT_REVERB" = 0 ]; then
        tui_msg "未選擇任何服務，已取消"
        return 0
    fi

    local SCOPE=""
    [ "$WANT_QUEUE" = 1 ] && SCOPE="${SCOPE:+$SCOPE+}queue"
    [ "$WANT_SCHED" = 1 ] && SCOPE="${SCOPE:+$SCOPE+}sched"
    [ "$WANT_REVERB" = 1 ] && SCOPE="${SCOPE:+$SCOPE+}reverb"

    # 偵測範圍內既有 conf — 提早問覆蓋與否（範圍外的 conf 不動、不算覆蓋）
    local IS_UPDATE=0
    if { [ "$WANT_QUEUE" = 1 ] && has_queue_conf "$SHORT_NAME"; } || \
       { [ "$WANT_SCHED" = 1 ] && has_sched_conf "$SHORT_NAME"; } || \
       { [ "$WANT_REVERB" = 1 ] && has_reverb_conf "$SHORT_NAME"; }; then
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

    # === Queue 參數（範圍含 queue 才問）===
    local QC TRIES TIMEOUT QUEUE_NAME TRIES_NOTE=""
    if [ "$WANT_QUEUE" = 1 ]; then
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

        [ "$TRIES" = "1" ] && TRIES_NOTE=" (no retry)"
        [ "$TRIES" = "0" ] && TRIES_NOTE=" (unlimited)"
    fi

    # === Reverb 參數（範圍含 reverb 才問）===
    local RV_HOST RV_PORT
    if [ "$WANT_REVERB" = 1 ]; then
        if [ ! -d "$APP_PATH/vendor/laravel/reverb" ]; then
            tui_yesno "⚠ $DOMAIN 似未安裝 laravel/reverb\n（$APP_PATH/vendor/laravel/reverb 不存在）\n\n服務啟動後會 crash-loop（composer 找不到套件）。\n仍要建立 reverb 常駐服務設定？" || return 0
        fi

        # port 建議值：掃現有 *-reverb.conf 的 --port=NNNN 取 max+1，無則 8080
        local f p max_port=0 suggested_port
        for f in "$CONF_DIR"/*-reverb.conf; do
            [ -e "$f" ] || continue
            p=$(grep -m1 -oE -- '--port=[0-9]+' "$f" 2>/dev/null | cut -d= -f2)
            [ -n "$p" ] && [ "$p" -gt "$max_port" ] && max_port="$p"
        done
        if [ "$max_port" -gt 0 ]; then
            suggested_port=$(( max_port + 1 ))
        else
            suggested_port=8080
        fi

        RV_PORT=$(tui_input "Reverb 監聽 port\n\n建議依現有站點遞增分配，避免撞港" "$suggested_port") || return 0
        [ -z "$RV_PORT" ] && RV_PORT="$suggested_port"
        [[ "$RV_PORT" =~ ^[0-9]+$ ]] || { tui_msg "Port 必須是數字"; return 0; }
        if [ "$RV_PORT" -lt 1024 ] || [ "$RV_PORT" -gt 65535 ]; then
            tui_msg "Port 必須介於 1024–65535"; return 0
        fi
        if ss -tuln 2>/dev/null | grep -q ":$RV_PORT "; then
            tui_yesno "⚠ port $RV_PORT 目前已在監聽中，可能與其他服務衝突。\n\n仍要使用這個 port？" || return 0
        fi

        RV_HOST=$(tui_input "Reverb 監聽位址（host）\n\n建議維持 127.0.0.1，藏在 nginx 反代後；\n不建議改 0.0.0.0（port 會直接對外裸露）" "127.0.0.1") || return 0
        [ -z "$RV_HOST" ] && RV_HOST="127.0.0.1"
    fi

    # 摘要 + 最終確認
    local VERB="啟用"
    [ "$IS_UPDATE" = 1 ] && VERB="更新"

    local SUMMARY="網域:           $DOMAIN
App:            $APP_PATH
User:           $USERNAME
範圍:           $(scope_label "$SCOPE")"
    if [ "$WANT_QUEUE" = 1 ]; then
        SUMMARY+="
Queue workers:  $QC
Tries:          $TRIES${TRIES_NOTE}
Timeout:        ${TIMEOUT}s/job
Queue:          $QUEUE_NAME"
    fi
    if [ "$WANT_REVERB" = 1 ]; then
        SUMMARY+="
Reverb:         $RV_HOST:$RV_PORT"
    fi

    tui_yesno "確認${VERB} Laravel 服務？

$SUMMARY" || return 0

    # storage / bootstrap/cache 權限
    chown -R "$USERNAME:$USERNAME" "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
    chmod -R 775 "$APP_PATH/storage" 2>/dev/null || true

    if [ "$WANT_QUEUE" = 1 ]; then
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
    fi

    if [ "$WANT_SCHED" = 1 ]; then
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
    fi

    if [ "$WANT_REVERB" = 1 ]; then
        cat > "$CONF_DIR/$SHORT_NAME-reverb.conf" <<EOP
[program:$SHORT_NAME-reverb]
directory=$APP_PATH
command=php artisan reverb:start --host=$RV_HOST --port=$RV_PORT
user=$USERNAME
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$APP_PATH/storage/logs/reverb.log
stopwaitsecs=30
EOP

        mkdir -p /etc/nginx/snippets
        cat > "/etc/nginx/snippets/reverb-$DOMAIN.conf" <<EOP
# [webops-managed]
# Reverb WebSocket reverse proxy for $DOMAIN
# 用法：把下面這行加進該站 vhost 的 server {} block，再驗證並套用
#   include snippets/reverb-$DOMAIN.conf;
#   nginx -t && systemctl reload nginx

location /app {
    proxy_pass http://$RV_HOST:$RV_PORT;
    proxy_set_header Host \$http_host;
    proxy_set_header Scheme \$scheme;
    proxy_set_header SERVER_PORT \$server_port;
    proxy_set_header REMOTE_ADDR \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
}

location /apps {
    proxy_pass http://$RV_HOST:$RV_PORT;
    proxy_set_header Host \$http_host;
    proxy_set_header Scheme \$scheme;
    proxy_set_header SERVER_PORT \$server_port;
    proxy_set_header REMOTE_ADDR \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOP
    fi

    local output
    output=$(supervisorctl reread 2>&1; supervisorctl update 2>&1)

    if [ "$IS_UPDATE" = 1 ]; then
        local -a progs=()
        [ "$WANT_QUEUE" = 1 ] && progs+=("$SHORT_NAME-queue:*")
        [ "$WANT_SCHED" = 1 ] && progs+=("$SHORT_NAME-sched")
        [ "$WANT_REVERB" = 1 ] && progs+=("$SHORT_NAME-reverb")
        local restart_out
        restart_out=$(supervisorctl restart "${progs[@]}" 2>&1 || true)
        output+=$'\n\n--- restart ---\n'"$restart_out"
    fi

    local REVERB_NOTE=""
    if [ "$WANT_REVERB" = 1 ]; then
        REVERB_NOTE="

—— Reverb 額外步驟（webops 不自動處理）——
1. Nginx：把下面這行加進 $DOMAIN 的 vhost server{} block，再驗證並套用
     include snippets/reverb-$DOMAIN.conf;
     nginx -t && systemctl reload nginx
2. App .env 自行設定：BROADCAST_CONNECTION=reverb、REVERB_APP_ID/KEY/SECRET、
   REVERB_HOST=$RV_HOST、REVERB_PORT=$RV_PORT、REVERB_SCHEME，以及前端 VITE_REVERB_*
3. 高併發連線數：全域 /etc/supervisor/supervisord.conf 的 minfds 建議調到 10000
   （需自行修改後 supervisorctl reread && supervisorctl update）
4. 優雅重啟（斷完連線後由 supervisor 拉起，客戶端會自動重連）：
     php artisan reverb:restart
   本工具的 restart 是 supervisorctl restart（立即斷線），需要優雅重啟請改用上面指令"
    fi

    tui_msg "✅ $DOMAIN 服務已${VERB}

$SUMMARY

supervisorctl 輸出:
$output$REVERB_NOTE"
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
    ACTION=$(tui_menu "Laravel 服務管理 (queue/sched/reverb, user=$USERNAME)" \
        "enable"  "啟用 / 更新服務" \
        "restart" "重啟服務（reload code 後常用）" \
        "status"  "狀態總覽（健康一覽：queue/sched/reverb + 異常站）" \
        "logs"    "檢視 worker / scheduler / reverb logs" \
        "list"    "列出網域（快速純清單）" \
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

            SEL=$(tui_pick_filtered "選擇要重啟的服務" "${items_with_all[@]}") || continue

            if [ "$SEL" = "__all__" ]; then
                tui_yesno "重啟全部 Laravel 服務（$N_SITES 站的 queue + sched + reverb）？\n\n（適合 shared library 升級後一次刷新；不影響其他 supervisor 程式；\n  reverb 走 supervisorctl restart 會立即斷線，Echo 客戶端會自動重連）" || continue
                declare -a all_progs=()
                while IFS= read -r short; do
                    [ -z "$short" ] && continue
                    # 只收集實際存在的 conf（queue-only / sched-only / reverb-only 站不塞不存在的 program）
                    has_queue_conf "$short" && all_progs+=("$short-queue:*")
                    has_sched_conf "$short" && all_progs+=("$short-sched")
                    has_reverb_conf "$short" && all_progs+=("$short-reverb")
                done < <(list_enabled_short_names)
                output=$(supervisorctl restart "${all_progs[@]}" 2>&1 || true)
                tui_msg "✅ 全部 Laravel 服務已重啟（$N_SITES 站）\n\n$output"
            else
                domain="${SEL//-/.}"
                SCOPE=$(pick_scope "$domain — 重啟哪些服務？" "$SEL") || continue
                LABEL=$(scope_label "$SCOPE")
                declare -a progs=()
                [[ "$SCOPE" == *queue* ]] && has_queue_conf "$SEL" && progs+=("$SEL-queue:*")
                [[ "$SCOPE" == *sched* ]] && has_sched_conf "$SEL" && progs+=("$SEL-sched")
                [[ "$SCOPE" == *reverb* ]] && has_reverb_conf "$SEL" && progs+=("$SEL-reverb")
                tui_yesno "重啟 $domain（$LABEL）？\n\n（適合 git pull / composer install 上新版 code 後執行；\n  worker 會優雅停止當前 job 後重啟；reverb 是 supervisorctl restart，會立即斷線；\n  優雅重啟 reverb 請改到該站手動跑 php artisan reverb:restart）" || continue
                output=$(supervisorctl restart "${progs[@]}" 2>&1 || true)
                tui_msg "✅ $domain 已重啟（$LABEL）\n\n$output"
            fi
            ;;

        status)
            content=$(render_status_overview)
            tui_scroll "Laravel 服務狀態總覽" "$content"
            ;;

        logs)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的服務"; continue
            fi

            SEL=$(tui_pick_filtered "選擇要檢視 logs 的服務" "${_enabled_items[@]}") || continue
            domain="${SEL//-/.}"

            LOG_TYPE=$(tui_menu "$domain — 選擇要看的 log" \
                "queue"  "queue worker.log（最後 200 行）" \
                "sched"  "scheduler.log（最後 200 行）" \
                "reverb" "reverb.log（最後 200 行）" \
                "both"   "全部合併（各 100 行；僅列出已啟用的服務）") || continue

            APP_PATH=$(get_app_path_from_conf "$CONF_DIR/$SEL-queue.conf")
            if [ -z "$APP_PATH" ]; then
                # fallback 鏈：queue → sched → reverb
                APP_PATH=$(get_app_path_from_conf "$CONF_DIR/$SEL-sched.conf")
            fi
            if [ -z "$APP_PATH" ]; then
                APP_PATH=$(get_app_path_from_conf "$CONF_DIR/$SEL-reverb.conf")
            fi
            if [ -z "$APP_PATH" ]; then
                tui_msg "❌ 找不到 $SEL 的 directory 設定"; continue
            fi

            QLOG="$APP_PATH/storage/logs/worker.log"
            SLOG="$APP_PATH/storage/logs/scheduler.log"
            RLOG="$APP_PATH/storage/logs/reverb.log"

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
                reverb)
                    if [ -f "$RLOG" ]; then
                        content=$(tail -n 200 "$RLOG" 2>&1 || echo "(讀取失敗)")
                    else
                        content="(尚無 $RLOG — 服務剛啟用 / 沒寫過 log)"
                    fi
                    tui_scroll "$domain — reverb.log (last 200)" "$content"
                    ;;
                both)
                    content=""
                    if has_queue_conf "$SEL"; then
                        content+="--- worker.log (last 100) ---"$'\n'
                        if [ -f "$QLOG" ]; then
                            content+="$(tail -n 100 "$QLOG" 2>&1 || echo '(讀取失敗)')"
                        else
                            content+="(尚無 $QLOG)"
                        fi
                        content+=$'\n\n'
                    fi
                    if has_sched_conf "$SEL"; then
                        content+="--- scheduler.log (last 100) ---"$'\n'
                        if [ -f "$SLOG" ]; then
                            content+="$(tail -n 100 "$SLOG" 2>&1 || echo '(讀取失敗)')"
                        else
                            content+="(尚無 $SLOG)"
                        fi
                        content+=$'\n\n'
                    fi
                    if has_reverb_conf "$SEL"; then
                        content+="--- reverb.log (last 100) ---"$'\n'
                        if [ -f "$RLOG" ]; then
                            content+="$(tail -n 100 "$RLOG" 2>&1 || echo '(讀取失敗)')"
                        else
                            content+="(尚無 $RLOG)"
                        fi
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

            SEL=$(tui_pick_filtered "選擇要檢視的服務" "${_enabled_items[@]}") || continue
            content="--- $SEL-queue.conf ---"$'\n'
            content+="$(cat "$CONF_DIR/$SEL-queue.conf" 2>/dev/null || echo '(無)')"
            content+=$'\n\n''--- '"$SEL"'-sched.conf ---'$'\n'
            content+="$(cat "$CONF_DIR/$SEL-sched.conf" 2>/dev/null || echo '(無)')"
            content+=$'\n\n''--- '"$SEL"'-reverb.conf ---'$'\n'
            content+="$(cat "$CONF_DIR/$SEL-reverb.conf" 2>/dev/null || echo '(無)')"
            tui_scroll "${SEL//-/.} 配置" "$content"
            ;;

        disable)
            build_enabled_items
            if [ "${#_enabled_items[@]}" -eq 0 ]; then
                tui_msg "目前無啟用中的 Laravel 服務"; continue
            fi

            SEL=$(tui_pick_filtered "選擇要停用的服務" "${_enabled_items[@]}") || continue
            domain="${SEL//-/.}"

            SCOPE=$(pick_scope "$domain — 停用哪些服務？" "$SEL") || continue
            LABEL=$(scope_label "$SCOPE")
            tui_yesno "確定停用並刪除 $domain 的服務配置（$LABEL）？" || continue

            if [[ "$SCOPE" == *queue* ]]; then
                supervisorctl stop "$SEL-queue:*" 2>/dev/null || true
                rm -f "$CONF_DIR/$SEL-queue.conf"
            fi
            if [[ "$SCOPE" == *sched* ]]; then
                supervisorctl stop "$SEL-sched" 2>/dev/null || true
                rm -f "$CONF_DIR/$SEL-sched.conf"
            fi
            REVERB_DISABLE_NOTE=""
            if [[ "$SCOPE" == *reverb* ]]; then
                supervisorctl stop "$SEL-reverb" 2>/dev/null || true
                rm -f "$CONF_DIR/$SEL-reverb.conf"
                REVERB_DISABLE_NOTE="

⚠ nginx snippet 不會自動刪除（/etc/nginx/snippets/reverb-$domain.conf）。
若該站 vhost 已 include 這個 snippet，請先移除 vhost 內的 include 行，
再自行刪除 snippet 檔，避免 nginx -t 失敗。"
            fi
            output=$(supervisorctl update 2>&1)
            tui_msg "✅ $domain（$LABEL）已從 supervisor 移除\n\n$output$REVERB_DISABLE_NOTE"
            ;;

        quit) exit 0 ;;
    esac
done
