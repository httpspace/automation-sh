#!/bin/bash
#
# domain-mgr.sh — 網域管理 TUI（主網域註冊 + Cloudflare DNS CRUD）
# 用法: sudo domain-mgr
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
command -v jq   >/dev/null 2>&1 || error "需要 jq（apt install -y jq）"
command -v curl >/dev/null 2>&1 || error "需要 curl"

if [ -z "${CF_Token:-}" ]; then
    error ".env 缺少 CF_Token"
fi

CF_API="https://api.cloudflare.com/client/v4"
WEBOPS_DIR="$(webops_dir)"
CF_DNS="$WEBOPS_DIR/cf-dns.sh"

# === 主迴圈 ===
while true; do
    CHOICE=$(tui_menu "選擇操作" \
        "add-sub"    "🆕 新增子網域（DNS A record）" \
        "rm-sub"     "🗑  刪除子網域（多選）" \
        "list-zone"  "📜 列出 zone 全部 DNS 記錄" \
        "reg-main"   "📝 註冊新主網域到 domains.conf" \
        "rm-main"    "❌ 從 domains.conf 移除主網域" \
        "show-conf"  "👁  顯示 domains.conf 內容" \
        "quit"       "離開") || exit 0

    case "$CHOICE" in
        add-sub)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            SUB=$(tui_input "輸入子網域前綴（例如 lab）") || continue
            [ -z "$SUB" ] && { tui_msg "未輸入子網域"; continue; }
            if "$CF_DNS" add "$SUB" "$MAIN" 2>&1 | tee /tmp/cf-dns-out >/dev/null; then
                tui_msg "已新增 $SUB.$MAIN\n\n$(cat /tmp/cf-dns-out)"
            else
                tui_msg "❌ 新增失敗：\n\n$(cat /tmp/cf-dns-out)"
            fi
            rm -f /tmp/cf-dns-out
            ;;

        rm-sub)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            ZID=$(domains_resolve_zone_id "$MAIN") || {
                tui_msg "❌ 找不到 $MAIN 的 zone_id\n（domains.conf 未填且 auto-discover 失敗）"
                continue
            }

            # 從 CF 拉所有記錄
            resp=$(curl -fsSL -G "$CF_API/zones/$ZID/dns_records?per_page=100" \
                -H "Authorization: Bearer $CF_Token")
            if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
                tui_msg "❌ Cloudflare 查詢失敗"
                continue
            fi

            # 組 checklist：tag = record_id；label = "name (type → content)"
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

            # SELECTED 是 "id1" "id2" ... 形式（whiptail 用引號分隔）
            tui_yesno "確認刪除以下記錄？\n\n$SELECTED" || continue

            # 解析 SELECTED（去引號），逐筆刪
            for rid in $(echo "$SELECTED" | tr -d '"'); do
                curl -fsSL -X DELETE "$CF_API/zones/$ZID/dns_records/$rid" \
                    -H "Authorization: Bearer $CF_Token" >/dev/null
            done
            tui_msg "✅ 已刪除選取記錄"
            ;;

        list-zone)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            content=$("$CF_DNS" ls "$MAIN" 2>&1 || true)
            tui_scroll "DNS 記錄" "$content"
            ;;

        reg-main)
            DOMAIN=$(tui_input "主網域（例如 example.com）") || continue
            [ -z "$DOMAIN" ] && continue
            if domains_exists "$DOMAIN"; then
                tui_msg "$DOMAIN 已存在於 domains.conf"
                continue
            fi
            ZID=$(tui_input "Cloudflare zone_id（可留空 → 由 token 自動探查；token 需有 Zone:Zone:Read）" "") || continue
            NOTE=$(tui_input "備註（用途說明，可留空）" "") || continue

            domains_add "$DOMAIN" "$ZID" "$NOTE"

            # 若使用者留空 zone_id，立刻嘗試 auto-discover 來驗證 token 權限
            if [ -z "$ZID" ]; then
                if discovered=$(domains_resolve_zone_id "$DOMAIN" 2>/dev/null); then
                    tui_msg "✅ 已註冊 $DOMAIN\n\nzone_id auto-discover 成功：${discovered:0:8}..（已快取）"
                else
                    tui_msg "✅ 已註冊 $DOMAIN（zone_id 留空）\n\n⚠️ Auto-discover 失敗 — 請確認 CF_Token 有 Zone:Zone:Read 權限，或手動編輯 domains.conf 補上 zone_id"
                fi
            else
                tui_msg "✅ 已註冊 $DOMAIN"
            fi
            ;;

        rm-main)
            domains_require_conf
            MAIN=$(tui_pick_domain) || continue
            tui_yesno "從 domains.conf 移除 $MAIN？\n（不會影響 Cloudflare 上的資料）" || continue
            domains_remove "$MAIN"
            tui_msg "✅ 已移除 $MAIN（從註冊表）"
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

        quit) exit 0 ;;
    esac
done
