#!/bin/bash
#
# webops.sh — webops 部署框架主入口（whiptail TUI）
# 用法: sudo webops
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"
# shellcheck source=lib/domains.sh
source "$LIB_DIR/domains.sh"
# shellcheck source=lib/sites.sh
source "$LIB_DIR/sites.sh"
# shellcheck source=lib/flows.sh
source "$LIB_DIR/flows.sh"

require_root
load_env

tui_available || error "需要 whiptail（apt install -y whiptail）"

WEBOPS_DIR="$(webops_dir)"
# 告知子模組（advanced / laravel-svc / repo-key）是由 webops 導覽進入，返回項顯示「返回」而非「離開」
export WEBOPS_NAV=1
# get_tag / managed_label / detect_status / list_subdomains_for / render_overview
# 都已移到 lib/sites.sh 共用

# === Splash（每個 session 一次；任意鍵立即進入，否則 WEBOPS_SPLASH_SECONDS 秒後自動進入）===
# .env 可設 WEBOPS_SPLASH_SECONDS（預設 1；設 0 = 完全跳過 splash）
show_splash() {
    local wait="${WEBOPS_SPLASH_SECONDS:-1}"
    [[ "$wait" =~ ^[0-9]+([.][0-9]+)?$ ]] || wait=1
    [ "$wait" = "0" ] && return 0

    local v host_short ts who
    v=$(webops_version)
    host_short=$(hostname -s 2>/dev/null || hostname)
    ts=$(date '+%Y-%m-%d %H:%M')
    who="${SUDO_USER:-$(whoami)}"

    # 方塊字 logo：上三行亮青、下三行藍，做出簡單漸層
    local CYAN='\033[1;36m' DIM='\033[2m'
    local -a logo=(
        '██╗    ██╗███████╗██████╗  ██████╗ ██████╗ ███████╗'
        '██║    ██║██╔════╝██╔══██╗██╔═══██╗██╔══██╗██╔════╝'
        '██║ █╗ ██║█████╗  ██████╔╝██║   ██║██████╔╝███████╗'
        '██║███╗██║██╔══╝  ██╔══██╗██║   ██║██╔═══╝ ╚════██║'
        '╚███╔███╔╝███████╗██████╔╝╚██████╔╝██║     ███████║'
        ' ╚══╝╚══╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝     ╚══════╝'
    )

    clear
    echo
    local i col
    for i in "${!logo[@]}"; do
        col="$CYAN"; [ "$i" -ge 3 ] && col="$BLUE"
        printf "   ${col}%s${NC}\n" "${logo[$i]}"
    done
    printf "   ${DIM}svc-app deployment framework${NC}  ${GREEN}v%s${NC}\n" "$v"
    echo
    printf "   ${YELLOW}%-7s${NC}%s\n" "Host"   "$host_short"
    printf "   ${YELLOW}%-7s${NC}%s\n" "User"   "$who"
    printf "   ${YELLOW}%-7s${NC}%s\n" "Time"   "$ts"
    printf "   ${YELLOW}%-7s${NC}%b\n" "Status" "$(build_status_line color)"
    echo
    printf "   ${DIM}按任意鍵進入 · %ss 後自動進入${NC}" "$wait"
    read -rsn 1 -t "$wait" || true
    echo
}

# === Status 計算（每次主選單繪製前算一次）===
# 用法: build_status_line [color]  — 帶 color 時數字上色（只給終端 splash 用；whiptail 不吃 ANSI）
build_status_line() {
    local n_main n_sites n_workers
    n_main=$(domains_list_names | grep -c . || true)
    n_sites=$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | tr -d ' ' || true)
    n_workers=$(supervisorctl status 2>/dev/null | grep -E 'queue|sched|reverb' | grep -c RUNNING || true)
    if [ "${1:-}" = "color" ]; then
        echo "${GREEN}${n_main}${NC} 主網域 · ${GREEN}${n_sites}${NC} 站點 · ${GREEN}${n_workers}${NC} worker 啟用"
    else
        echo "$n_main 主網域 · $n_sites 站點 · $n_workers worker 啟用"
    fi
}

count_active_scheds() {
    find /etc/supervisor/conf.d -maxdepth 1 -type f -name '*-sched.conf' 2>/dev/null | wc -l | tr -d ' ' || true
}

# === 啟動 splash（每個 session 一次）===
show_splash

# === 主選單（簡易模式：日常操作 + 進階模式入口）===
# 日常：網站一覽 / 加子網域（並部署）/ 部署新站 / Laravel 服務
# 進階模式（高風險、少用）：Cloudflare/網域、Nginx/站點、SSL、資料庫、Deploy Key — 見 advanced.sh
while true; do
    STATUS_LINE=$(build_status_line)

    N_SCHEDS=$(count_active_scheds)
    LARAVEL_LABEL="排程 + Queue + Reverb"
    [ "$N_SCHEDS" -gt 0 ] && LARAVEL_LABEL="排程 + Queue + Reverb ($N_SCHEDS 啟用)"

    CHOICE=$(tui_nav_menu "" "離開" "$STATUS_LINE

選擇操作" \
        "overview"   "網站一覽" \
        "add-sub"    "加子網域（並部署）" \
        "deploy"     "部署新站" \
        "laravel"    "Laravel 服務（$LARAVEL_LABEL）" \
        "advanced"   "進階模式 ▸" \
        "quit"       "✕ 離開 webops") || exit 0

    case "$CHOICE" in
        overview)
            content=$(render_overview)
            tui_scroll "網站一覽" "$content"
            ;;

        add-sub)
            # 流程抽到 lib/flows.sh，與進階模式「Cloudflare / 網域 › 加子網域」共用
            flow_add_sub
            ;;

        deploy)
            # deploy-site 自己是互動式 whiptail TUI，不能包進 tui_run_with_log
            # （會把 whiptail 的 UI 跟結果都吃進 log 檔，使用者看不到對話框）
            "$WEBOPS_DIR/deploy-site.sh" || true
            ;;

        laravel)
            "$WEBOPS_DIR/laravel-svc.sh"
            ;;

        advanced)
            if tui_yesno "進階模式包含刪除子網域、刪除站點、重設 acme.sh、移除主網域等高風險操作。\n\n確定進入？"; then
                "$WEBOPS_DIR/advanced.sh"
            fi
            ;;

        quit) exit 0 ;;
    esac
done
