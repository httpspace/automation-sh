#!/bin/bash
#
# site-mgr.sh — 已部署站點清單與管理（TUI）
# 用法: sudo site-mgr
#
# 識別兩種 webops/legacy 標籤：
#   # [webops-managed]    → 新版部署
#   # [EasyAI-Managed]    → 舊版部署（向前相容）
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"

require_root

CONF_DIR="/etc/nginx/conf.d"
BACKUP_DIR="$CONF_DIR/deleted_backups"

# 從 conf 標頭取值（# [Key: value]）
get_tag() {
    local conf="$1" key="$2"
    grep -m1 "^# \[$key: " "$conf" 2>/dev/null | sed -E "s/^# \[$key: (.*)\]$/\1/"
}

# 判斷是否為 webops/legacy 管理
is_managed() {
    local conf="$1"
    grep -qE '^# \[(webops-managed|EasyAI-Managed)\]' "$conf" 2>/dev/null
}

# 取得管理類型標籤（給顯示用）
managed_label() {
    local conf="$1"
    if grep -q '^# \[webops-managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED"
    elif grep -q '^# \[EasyAI-Managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED*"   # 星號標示舊版
    else
        echo "MANUAL"
    fi
}

# 偵測站點狀態（若有 port 看 ss；laravel/php 顯示模式名）
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

list_confs() {
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort
}

# === 主迴圈 ===
while true; do
    clear
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${GREEN}             🌐  webops 站點管理（site-mgr）${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf "%-4s %-32s %-10s %-12s %s\n" "ID" "網域" "類型" "Mode" "狀態"
    echo -e "----------------------------------------------------------------------------"

    declare -a DOMAINS=()
    i=1
    while IFS= read -r conf; do
        [ -z "$conf" ] && continue
        domain=$(basename "$conf" .conf)
        DOMAINS[$i]="$domain"

        type_label=$(managed_label "$conf")
        if is_managed "$conf"; then
            mode=$(get_tag "$conf" "Mode")
            port=$(get_tag "$conf" "Port")
            status=$(detect_status "$mode" "$port")
            type_color="${GREEN}${type_label}${NC}"
        else
            mode="-"
            status="-"
            type_color="${YELLOW}${type_label}${NC}"
        fi

        printf "[%2d] %-32s %-20b %-12s %s\n" "$i" "$domain" "$type_color" "$mode" "$status"
        i=$((i+1))
    done < <(list_confs)

    echo -e "----------------------------------------------------------------------------"
    echo -e "${YELLOW}操作:${NC} [數字] 刪除站點   c <數字>) 檢視 conf   q) 離開"
    echo -e "       備註：MANAGED* 為舊版 [EasyAI-Managed]，刪除流程相同"
    read -rp "指令: " CMD

    if [[ "$CMD" =~ ^[0-9]+$ ]]; then
        sel="${DOMAINS[$CMD]:-}"
        if [ -z "$sel" ]; then
            warn "無效編號"; sleep 1; continue
        fi
        conf_file="$CONF_DIR/$sel.conf"
        if ! is_managed "$conf_file"; then
            warn "$sel 為手動配置（MANUAL），site-mgr 不刪除手動站；請自行管理"
            sleep 2; continue
        fi

        echo -e "\n${RED}⚠️  確定刪除 $sel？${NC}"
        read -rp "請輸入完整網域以確認: " confirm
        if [ "$confirm" = "$sel" ]; then
            mkdir -p "$BACKUP_DIR"
            mv "$conf_file" "$BACKUP_DIR/$sel.conf.bak.$(date +%Y%m%d%H%M%S)"
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx
                info "✅ $sel 已移除（備份於 $BACKUP_DIR）"
            else
                error "nginx -t 失敗；請檢查 $BACKUP_DIR 內備份並手動處理"
            fi
            sleep 1
        else
            warn "輸入不符，取消刪除"
            sleep 1
        fi

    elif [[ "$CMD" =~ ^c[[:space:]]+([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        sel="${DOMAINS[$idx]:-}"
        if [ -n "$sel" ]; then
            less "$CONF_DIR/$sel.conf"
        else
            warn "無效編號"; sleep 1
        fi

    elif [ "$CMD" = "q" ]; then
        exit 0
    fi
done
