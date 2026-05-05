#!/bin/bash
# webops/lib/tui.sh — whiptail TUI 包裝
# 此檔案僅供 source，不直接執行。

# 共通標題
WEBOPS_TUI_TITLE="${WEBOPS_TUI_TITLE:-🚀 webops 部署框架}"

# 偵測 whiptail 是否存在
tui_available() {
    command -v whiptail >/dev/null 2>&1
}

# 主選單
# 用法: choice=$(tui_menu "提示" "tag1" "label1" "tag2" "label2" ...)
# 取消會 return 1。
tui_menu() {
    local prompt="$1"; shift
    whiptail --title "$WEBOPS_TUI_TITLE" --menu "$prompt" 20 76 12 "$@" 3>&1 1>&2 2>&3
}

# 文字輸入
# 用法: val=$(tui_input "提示" ["預設值"])
tui_input() {
    local prompt="$1"
    local default="${2:-}"
    whiptail --title "$WEBOPS_TUI_TITLE" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
}

# Yes/No 確認
# 用法: tui_yesno "問題" && echo yes || echo no
tui_yesno() {
    local prompt="$1"
    whiptail --title "$WEBOPS_TUI_TITLE" --yesno "$prompt" 10 70
}

# 訊息框
tui_msg() {
    local prompt="$1"
    whiptail --title "$WEBOPS_TUI_TITLE" --msgbox "$prompt" 14 76
}

# Checklist 多選
# 用法: tui_checklist "提示" "tag1" "label1" "ON|OFF" "tag2" "label2" "ON|OFF" ...
tui_checklist() {
    local prompt="$1"; shift
    whiptail --title "$WEBOPS_TUI_TITLE" --checklist "$prompt" 20 76 12 "$@" 3>&1 1>&2 2>&3
}

# 大文字顯示（捲動）
tui_scroll() {
    local prompt="$1"
    local content="$2"
    whiptail --title "$WEBOPS_TUI_TITLE" --scrolltext --msgbox "$content" 22 90
}

# 選擇主網域（從 domains.conf）
# 用法: domain=$(tui_pick_domain) — 會列出註冊表內所有主網域；無註冊時 return 1
tui_pick_domain() {
    local list args=()
    list=$(domains_list_names) || return 1
    if [ -z "$list" ]; then
        tui_msg "尚未註冊任何主網域。\n請先到「網域管理 → 註冊新主網域」加入第一筆。"
        return 1
    fi
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        args+=("$d" "$(domains_get_note "$d")")
    done <<< "$list"
    tui_menu "選擇主網域" "${args[@]}"
}
