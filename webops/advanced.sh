#!/bin/bash
#
# advanced.sh — webops 進階維運子選單（whiptail TUI）
# 收納 Nginx 控制、acme 重設、備份、刪除網域 / DNS、查 conf 等少用操作。
# 用法: sudo advanced（透過 webops 主選單第 7 項，或直接 CLI 呼叫）
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
WEBOPS_TUI_TITLE="webops › 進階維運"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"
# shellcheck source=lib/domains.sh
source "$LIB_DIR/domains.sh"

require_root
load_env
tui_available || error "需要 whiptail（apt install -y whiptail）"

WEBOPS_DIR="$(webops_dir)"
REPO_DIR="$(dirname "$WEBOPS_DIR")"

while true; do
    CHOICE=$(tui_menu "進階維運" \
        "nginx"      "Nginx 控制（reload / restart / test）" \
        "acme"       "重設 acme.sh / 刷新 CF token" \
        "backup"     "立刻執行資料庫備份" \
        "rm-sub"     "刪除子網域（CF DNS，多選）" \
        "rm-main"    "移除主網域註冊（不影響 CF 上資料）" \
        "list-zone"  "列出 CF zone 全部 DNS 記錄" \
        "show-conf"  "顯示 domains.conf 內容" \
        "back"       "返回主選單") || exit 0

    case "$CHOICE" in
        nginx)
            NGX=$(tui_menu "Nginx 控制" \
                "reload"  "Reload（軟重載）" \
                "restart" "Restart（硬重啟）" \
                "test"    "Test（nginx -t）") || continue
            tui_run_with_log "Nginx $NGX" "$WEBOPS_DIR/nginx-ctl.sh" "$NGX"
            ;;

        acme)
            tui_yesno "重跑 install_acme.sh？\n\n會用 .env 的 CF_Token 同步到 /root/.acme.sh/account.conf。\nacme.sh 已裝會跳過 curl 安裝，只更新 token。" \
                && tui_run_with_log "重設 acme.sh / 刷新 CF token" "$REPO_DIR/install_acme.sh"
            ;;

        backup)
            tui_yesno "立刻執行 backup_databases.sh？\n\n會依 .env 的 BACKUP_DBS 設定備份到 BACKUP_DIR。" \
                && tui_run_with_log "資料庫備份" "$REPO_DIR/backup_databases.sh"
            ;;

        rm-sub)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            ZID=$(domains_resolve_zone_id "$MAIN") || {
                tui_msg "❌ 找不到 $MAIN 的 zone_id\n（domains.conf 未填且 auto-discover 失敗）"
                continue
            }

            command -v jq >/dev/null 2>&1 || { tui_msg "需要 jq（apt install -y jq）"; continue; }

            resp=$(curl -fsSL -G "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records?per_page=100" \
                -H "Authorization: Bearer $CF_Token" 2>/dev/null) || {
                tui_msg "❌ Cloudflare API 連線失敗"
                continue
            }

            if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
                tui_msg "❌ Cloudflare 查詢失敗"
                continue
            fi

            declare -a items=()
            while IFS=$'\t' read -r rid rname rtype rcontent; do
                [ -z "$rid" ] && continue
                items+=("$rid" "$rname ($rtype → $rcontent)" "OFF")
            done < <(echo "$resp" | jq -r '.result[] | "\(.id)\t\(.name)\t\(.type)\t\(.content)"')

            if [ "${#items[@]}" -eq 0 ]; then
                tui_msg "$MAIN zone 內沒有 DNS 記錄。"
                continue
            fi

            SELECTED=$(tui_checklist "勾選要刪除的記錄（空白鍵切換）" "${items[@]}") || continue
            [ -z "$SELECTED" ] && continue

            tui_yesno "確認刪除以下記錄？\n\n$SELECTED" || continue

            for rid in $(echo "$SELECTED" | tr -d '"'); do
                curl -fsSL -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records/$rid" \
                    -H "Authorization: Bearer $CF_Token" >/dev/null 2>&1 || true
            done
            tui_msg "✅ 已刪除選取記錄"
            ;;

        rm-main)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            tui_yesno "從 domains.conf 移除 $MAIN？\n\n（不會影響 Cloudflare 上的資料；只是 webops 不再認識這個主網域）" || continue
            domains_remove "$MAIN"
            tui_msg "✅ 已從 domains.conf 移除 $MAIN"
            ;;

        list-zone)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            content=$("$WEBOPS_DIR/cf-dns.sh" ls "$MAIN" 2>&1 || true)
            tui_scroll "$MAIN — DNS 記錄" "$content"
            ;;

        show-conf)
            f=$(domains_conf_path)
            if [ -f "$f" ]; then
                content=$(cat "$f")
                tui_scroll "domains.conf" "$content"
            else
                tui_msg "尚未建立 domains.conf"
            fi
            ;;

        back) exit 0 ;;
    esac
done
