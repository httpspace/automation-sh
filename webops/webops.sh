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

# === 主選單（5 個核心 + 站點管理 + 進階） ===
while true; do
    CHOICE=$(tui_menu "webops（svc-app 部署框架）" \
        "overview"   "網站一覽（所有主+子網域與站點狀態）" \
        "add-main"   "加主網域（註冊到 domains.conf）" \
        "add-sub"    "加子網域（Cloudflare DNS A record）" \
        "deploy"     "部署新站（主網域 / 子網域皆可）" \
        "laravel"    "排程 + Queue 設定（Laravel queue/sched）" \
        "site"       "站點管理（檢視 / 刪除）" \
        "advanced"   "進階（Nginx / acme / 備份 / 刪除網域 / DNS）" \
        "quit"       "離開") || exit 0

    case "$CHOICE" in
        overview)
            content=$(build_overview)
            tui_scroll "網站一覽" "$content"
            ;;

        add-main)
            DOMAIN=$(tui_input "主網域（例如 example.com）") || continue
            [ -z "$DOMAIN" ] && continue
            if domains_exists "$DOMAIN"; then
                tui_msg "$DOMAIN 已存在於 domains.conf"
                continue
            fi
            ZID=$(tui_input "Cloudflare zone_id（可留空 → 用 .env 的 CF_Token 自動探查；token 需有 Zone:Zone:Read）" "") || continue
            NOTE=$(tui_input "備註（用途，可留空）" "") || continue

            domains_add "$DOMAIN" "$ZID" "$NOTE"

            if [ -z "$ZID" ]; then
                if discovered=$(domains_resolve_zone_id "$DOMAIN" 2>/dev/null); then
                    tui_msg "✅ 已加入 $DOMAIN\n\nzone_id auto-discover 成功：${discovered:0:8}..（已快取）\n來源：.env 的 CF_Token"
                else
                    tui_msg "✅ 已加入 $DOMAIN（zone_id 留空）\n\n⚠️  Auto-discover 失敗 — 請確認 .env 的 CF_Token 有 Zone:Zone:Read 權限，或手動編輯 domains.conf 補上 zone_id"
                fi
            else
                tui_msg "✅ 已加入 $DOMAIN"
            fi
            ;;

        add-sub)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            SUB=$(tui_input "子網域前綴（例如 lab；輸入 @ 表示主網域 apex 本身）") || continue
            [ -z "$SUB" ] && continue

            output=$("$WEBOPS_DIR/cf-dns.sh" add "$SUB" "$MAIN" 2>&1) && rc=0 || rc=$?
            if [ "$rc" = 0 ]; then
                tui_msg "✅ DNS 記錄已建立\n\n$output"
            else
                tui_msg "❌ 失敗 (exit $rc)\n\n$output"
            fi
            ;;

        deploy)
            tui_run_with_log "部署新站" "$WEBOPS_DIR/deploy-site.sh"
            ;;

        laravel)
            "$WEBOPS_DIR/laravel-svc.sh"
            ;;

        site)
            "$WEBOPS_DIR/site-mgr.sh"
            ;;

        advanced)
            "$WEBOPS_DIR/advanced.sh"
            ;;

        quit) exit 0 ;;
    esac
done
