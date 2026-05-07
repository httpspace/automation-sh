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

require_root
load_env

tui_available || error "需要 whiptail（apt install -y whiptail）"

WEBOPS_DIR="$(webops_dir)"
# get_tag / managed_label / detect_status / list_subdomains_for / render_overview
# 都已移到 lib/sites.sh 共用

# === Status 計算（每次主選單繪製前算一次）===
build_status_line() {
    local n_main n_sites n_workers
    n_main=$(domains_list_names | grep -c .)
    n_sites=$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
    n_workers=$(supervisorctl status 2>/dev/null | grep -E 'queue|sched' | grep -c RUNNING)
    echo "$n_main 主網域 · $n_sites 站點 · $n_workers worker 啟用"
}

count_active_scheds() {
    find /etc/supervisor/conf.d -maxdepth 1 -type f -name '*-sched.conf' 2>/dev/null | wc -l | tr -d ' '
}

# === 主選單（5 個核心 + admin 入口）===
# 夥伴常用：加子網域 / 部署新站 / 排程 + Queue
# admin 維護：管理員工具（站點管理 / 加主網域 / Nginx / acme / 備份 / DNS）
while true; do
    STATUS_LINE=$(build_status_line)

    N_SCHEDS=$(count_active_scheds)
    LARAVEL_LABEL="排程 + Queue 設定"
    [ "$N_SCHEDS" -gt 0 ] && LARAVEL_LABEL="排程 + Queue 設定 ($N_SCHEDS 啟用)"

    CHOICE=$(tui_menu "$STATUS_LINE

選擇操作" \
        "overview"   "網站一覽" \
        "add-sub"    "加子網域" \
        "deploy"     "部署新站" \
        "laravel"    "$LARAVEL_LABEL" \
        "advanced"   "管理員工具" \
        "quit"       "離開") || exit 0

    case "$CHOICE" in
        overview)
            content=$(render_overview)
            tui_scroll "網站一覽" "$content"
            ;;

        add-sub)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            SUB=$(tui_input "子網域前綴（例如 lab；留空或 @ = 主網域 $MAIN apex 本身）" "") || continue
            # 不阻擋空 SUB — cf-dns.sh add 處理「空 / @」一律當 apex
            output=$("$WEBOPS_DIR/cf-dns.sh" add "$SUB" "$MAIN" 2>&1) && rc=0 || rc=$?
            if [ "$rc" = 0 ]; then
                tui_msg "✅ DNS 記錄已建立\n\n$output"
            else
                tui_msg "❌ 失敗 (exit $rc)\n\n$output"
            fi
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
            "$WEBOPS_DIR/advanced.sh"
            ;;

        quit) exit 0 ;;
    esac
done
