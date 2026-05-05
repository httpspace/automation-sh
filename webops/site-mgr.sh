#!/bin/bash
#
# site-mgr.sh — 已部署站點清單與管理（原生 whiptail TUI）
# 用法: sudo site-mgr
#
# 識別 webops 與 legacy 標籤：
#   # [webops-managed]    → 新版部署
#   # [EasyAI-Managed]    → 舊版部署（向前相容）
#
# 系統防呆：拒絕刪除 phpMyAdmin 站、拒絕刪除 MANUAL（手動配置）站。
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"

require_root
tui_available || error "需要 whiptail（apt install -y whiptail）"

CONF_DIR="/etc/nginx/conf.d"
BACKUP_DIR="$CONF_DIR/deleted_backups"

get_tag() {
    local conf="$1" key="$2"
    grep -m1 "^# \[$key: " "$conf" 2>/dev/null | sed -E "s/^# \[$key: (.*)\]$/\1/"
}

is_managed() {
    grep -qE '^# \[(webops-managed|EasyAI-Managed)\]' "$1" 2>/dev/null
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
            echo "Online($port)"
        else
            echo "Down($port)"
        fi
    elif [ "$mode" = "laravel" ]; then
        echo "Laravel"
    elif [ "$mode" = "php" ]; then
        echo "PHP"
    else
        echo "-"
    fi
}

is_phpmyadmin_site() {
    local domain="$1" conf="$2"
    echo "$domain" | grep -qiE 'phpmyadmin' \
        || grep -qE '/var/www/html/phpmyadmin' "$conf" 2>/dev/null
}

# === 主迴圈 ===
while true; do
    # 建構選單：每行 site
    declare -a items=()
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        domain=$(basename "$f" .conf)
        label=$(managed_label "$f")
        if [ "$label" != "MANUAL" ]; then
            mode=$(get_tag "$f" "Mode")
            port=$(get_tag "$f" "Port")
            status=$(detect_status "$mode" "$port")
            items+=("$domain" "[$label] $mode${port:+:$port} $status")
        else
            items+=("$domain" "[MANUAL] -")
        fi
    done < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)

    if [ "${#items[@]}" -eq 0 ]; then
        tui_msg "目前 $CONF_DIR 內沒有 .conf 站點"
        exit 0
    fi

    items+=("__quit__" "離開")

    SEL=$(tui_menu "選擇站點（MANAGED*=舊版 [EasyAI-Managed]）" "${items[@]}") || exit 0
    [ "$SEL" = "__quit__" ] && exit 0

    conf_file="$CONF_DIR/$SEL.conf"

    ACTION=$(tui_menu "$SEL — 選擇動作" \
        "view"   "檢視 conf 內容" \
        "delete" "刪除（移到 deleted_backups）") || continue

    case "$ACTION" in
        view)
            content=$(cat "$conf_file")
            tui_scroll "$SEL" "$content"
            ;;
        delete)
            # 防呆 1：phpMyAdmin
            if is_phpmyadmin_site "$SEL" "$conf_file"; then
                tui_msg "$SEL 看起來是 phpMyAdmin 站\n\nsite-mgr 拒絕刪除（系統防呆）。\n如真要移除，請手動處理 $conf_file"
                continue
            fi

            # 防呆 2：MANUAL（非 webops 部署）
            if ! is_managed "$conf_file"; then
                tui_msg "$SEL 為手動配置（MANUAL）\n\nsite-mgr 不刪除手動站；\n請手動編輯或刪除 $conf_file"
                continue
            fi

            # 二次確認：必須輸入完整網域
            confirm=$(tui_input "確認刪除 $SEL — 請輸入完整網域名稱以確認" "") || continue
            if [ "$confirm" != "$SEL" ]; then
                tui_msg "輸入「$confirm」不符，取消刪除"
                continue
            fi

            mkdir -p "$BACKUP_DIR"
            mv "$conf_file" "$BACKUP_DIR/$SEL.conf.bak.$(date +%Y%m%d%H%M%S)"

            if nginx -t 2>/tmp/nginx-test.log; then
                systemctl reload nginx
                tui_msg "✅ $SEL 已移除\n\n備份：$BACKUP_DIR/$SEL.conf.bak.*"
            else
                err=$(cat /tmp/nginx-test.log)
                rm -f /tmp/nginx-test.log
                tui_msg "❌ nginx -t 失敗\n\n$err\n\n備份保留於 $BACKUP_DIR；請手動處理"
            fi
            ;;
    esac
done
