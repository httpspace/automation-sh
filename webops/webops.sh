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
            content=$(render_overview)
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

        site)
            "$WEBOPS_DIR/site-mgr.sh"
            ;;

        advanced)
            "$WEBOPS_DIR/advanced.sh"
            ;;

        quit) exit 0 ;;
    esac
done
