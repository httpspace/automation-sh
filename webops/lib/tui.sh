#!/bin/bash
# webops/lib/tui.sh — whiptail TUI 包裝
# 此檔案僅供 source，不直接執行。

# 共通標題（caller 可預先 set WEBOPS_TUI_TITLE 覆寫成麵包屑，例如「webops › 站點管理」）
WEBOPS_TUI_TITLE="${WEBOPS_TUI_TITLE:-webops v$(webops_version) • svc-app deploy}"

# 恆顯狀態列（whiptail backtitle — 螢幕頂端、所有對話框都看得到）
# 格式: <hostname> • webops v<ver> • via <user>
WEBOPS_BACKTITLE="${WEBOPS_BACKTITLE:-$(hostname -s 2>/dev/null || hostname) • webops v$(webops_version) • via ${SUDO_USER:-$(whoami)}}"

# 偵測 whiptail 是否存在
tui_available() {
    command -v whiptail >/dev/null 2>&1
}

# 主選單
tui_menu() {
    local prompt="$1"; shift
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --menu "$prompt" 20 76 12 "$@" 3>&1 1>&2 2>&3
}

# 文字輸入
tui_input() {
    local prompt="$1"
    local default="${2:-}"
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
}

# Yes/No 確認
tui_yesno() {
    local prompt="$1"
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --yesno "$prompt" 10 70
}

# 訊息框
tui_msg() {
    local prompt="$1"
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --msgbox "$prompt" 14 76
}

# Checklist 多選
tui_checklist() {
    local prompt="$1"; shift
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --checklist "$prompt" 20 76 12 "$@" 3>&1 1>&2 2>&3
}

# 大文字顯示（捲動）
tui_scroll() {
    local prompt="$1"
    local content="$2"
    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$WEBOPS_TUI_TITLE" --scrolltext --msgbox "$content" 22 90
}

# 執行命令、capture 全部 stdout+stderr，結束後 textbox 顯示完整輸出。
tui_run_with_log() {
    local title="$1"; shift
    local log; log=$(mktemp)
    local rc=0

    whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$title" --infobox "執行中... 請稍候" 7 60

    "$@" >"$log" 2>&1 || rc=$?

    if [ "$rc" = 0 ]; then
        whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$title — ✅ 完成" --scrolltext --textbox "$log" 24 100
    else
        whiptail --backtitle "$WEBOPS_BACKTITLE" --title "$title — ❌ 失敗 (exit $rc)" --scrolltext --textbox "$log" 24 100
    fi
    rm -f "$log"
    return "$rc"
}

# 選擇主網域（從 domains.conf）
# 用法: domain=$(tui_pick_domain) — 會列出註冊表內所有主網域；無註冊時 return 1
tui_pick_domain() {
    local list args=()
    list=$(domains_list_names) || return 1
    if [ -z "$list" ]; then
        tui_msg "尚未註冊任何主網域。\n請先在主選單選「加主網域」加入第一筆。"
        return 1
    fi
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        args+=("$d" "$(domains_get_note "$d")")
    done <<< "$list"
    tui_menu "選擇主網域" "${args[@]}"
}
