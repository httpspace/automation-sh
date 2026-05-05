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

require_root
load_env

tui_available || error "需要 whiptail（apt install -y whiptail）"

WEBOPS_DIR="$(webops_dir)"
CONF_DIR="/etc/nginx/conf.d"

# === 網域總覽 ===
# 從 domains.conf 取主網域，列出 nginx 上對應子網域的狀態。
# 同時偵測 nginx 上有 conf 但主網域未註冊的「未註冊」項。
get_tag() {
    local conf="$1" key="$2"
    grep -m1 "^# \[$key: " "$conf" 2>/dev/null | sed -E "s/^# \[$key: (.*)\]$/\1/"
}

managed_label() {
    local conf="$1"
    if grep -q '^# \[webops-managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED"
    elif grep -q '^# \[EasyAI-Managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED*"
    else
        echo "MANUAL"
    fi
}

detect_status() {
    local mode="$1" port="$2"
    if [ -n "$port" ] && [ "$port" != "-" ]; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "● Online($port)"
        else
            echo "○ Down($port)"
        fi
    elif [ "$mode" = "laravel" ]; then
        echo "● Laravel"
    elif [ "$mode" = "php" ]; then
        echo "● PHP"
    else
        echo "-"
    fi
}

# 列出對應主網域的子網域 conf
list_subdomains_for() {
    local main="$1"
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null \
        | while IFS= read -r f; do
            local d
            d=$(basename "$f" .conf)
            if [ "$d" = "$main" ] || [[ "$d" == *".$main" ]]; then
                printf '%s\t%s\n' "$d" "$f"
            fi
        done
}

build_overview() {
    local out=""
    local registered_mains
    registered_mains=$(domains_list_names)

    if [ -z "$registered_mains" ]; then
        out+="尚未註冊任何主網域。\n請從「網域管理 → 註冊新主網域」開始。\n"
        echo -e "$out"
        return
    fi

    # 先收集所有 nginx confs 以便標記未註冊
    declare -A claimed_confs=()

    while IFS= read -r main; do
        [ -z "$main" ] && continue
        local zid zid_short
        zid=$(domains_get_zone_id_cached "$main" 2>/dev/null || true)
        if [ -n "$zid" ]; then
            zid_short="${zid:0:4}..${zid: -1}"
        else
            zid_short="? (auto-discover on next op)"
        fi

        out+="🌐 $main  (zone: $zid_short)\n"

        local subs
        subs=$(list_subdomains_for "$main")
        if [ -z "$subs" ]; then
            out+="   └─ （尚無子網域 nginx 設定）\n"
        else
            local lines
            lines=$(echo "$subs" | wc -l)
            local n=0
            while IFS=$'\t' read -r d f; do
                [ -z "$d" ] && continue
                claimed_confs["$f"]=1
                n=$((n+1))
                local prefix="├─"
                [ "$n" = "$lines" ] && prefix="└─"

                local label mode port status
                label=$(managed_label "$f")
                if [ "$label" != "MANUAL" ]; then
                    mode=$(get_tag "$f" "Mode")
                    port=$(get_tag "$f" "Port")
                    status=$(detect_status "$mode" "$port")
                    out+="   $prefix $d   [$label]  $mode${port:+:$port}   $status\n"
                else
                    out+="   $prefix $d   [MANUAL]  -\n"
                fi
            done <<< "$subs"
        fi
        out+="\n"
    done <<< "$registered_mains"

    # 未註冊區
    local unreg=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -z "${claimed_confs[$f]:-}" ]; then
            local d label
            d=$(basename "$f" .conf)
            label=$(managed_label "$f")
            unreg+="   └─ $d   [$label]\n"
        fi
    done < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)

    if [ -n "$unreg" ]; then
        out+="⚠️  未註冊（在 nginx 但不在 domains.conf）\n$unreg"
    fi

    echo -e "$out"
}

# === 主選單 ===
REPO_DIR="$(dirname "$WEBOPS_DIR")"

while true; do
    CHOICE=$(tui_menu "選擇操作（svc-app 部署框架）" \
        "overview"   "網域總覽（所有主+子網域與站點狀態）" \
        "domain"     "網域管理（DNS / 註冊主網域）" \
        "deploy"     "部署新站" \
        "site"       "站點管理（list / delete）" \
        "laravel"    "Laravel 服務管理（queue / sched）" \
        "nginx"      "Nginx 控制（reload / restart / test）" \
        "acme"       "重設 acme.sh / 刷新 CF token" \
        "backup"     "立刻執行資料庫備份" \
        "quit"       "離開") || exit 0

    case "$CHOICE" in
        overview)
            content=$(build_overview)
            tui_scroll "網域總覽" "$content"
            ;;
        domain)
            # domain-mgr 自己是 TUI 子迴圈，不包進 textbox
            "$WEBOPS_DIR/domain-mgr.sh"
            ;;
        deploy)
            tui_run_with_log "部署新站" "$WEBOPS_DIR/deploy-site.sh"
            ;;
        site)
            # site-mgr 自己是 whiptail 子迴圈，直接呼叫
            "$WEBOPS_DIR/site-mgr.sh"
            ;;
        laravel)
            # laravel-svc 自己是 whiptail 子迴圈，直接呼叫
            "$WEBOPS_DIR/laravel-svc.sh"
            ;;
        nginx)
            NGX=$(tui_menu "Nginx 控制" \
                "reload"  "Reload（軟重載）" \
                "restart" "Restart（硬重啟）" \
                "test"    "Test（nginx -t）") || continue
            tui_run_with_log "Nginx $NGX" "$WEBOPS_DIR/nginx-ctl.sh" "$NGX"
            ;;
        acme)
            if tui_yesno "重跑 install_acme.sh？\n\n會用 .env 裡的 CF_Token 同步到 /root/.acme.sh/account.conf。\nacme.sh 已裝會跳過 curl 安裝，只更新 token。"; then
                tui_run_with_log "重設 acme.sh / 刷新 CF token" "$REPO_DIR/install_acme.sh"
            fi
            ;;
        backup)
            if tui_yesno "立刻執行 backup_databases.sh？\n\n會依 .env 裡的 BACKUP_DBS 設定備份到 BACKUP_DIR。"; then
                tui_run_with_log "資料庫備份" "$REPO_DIR/backup_databases.sh"
            fi
            ;;
        quit) exit 0 ;;
    esac
done
