#!/bin/bash
# webops/lib/common.sh — 共用 helper：顏色、log、權限、.env 載入
# 此檔案僅供 source，不直接執行。

# === whiptail 暗色主題（被 source 後自動套用全部 webops 對話框） ===
# 色調：深色中性底＋綠色強調（焦點／選取），邊框收斂成灰、標題白字
# 色名必須是 newt/S-Lang 合法名稱（black red green brown blue magenta cyan lightgray
# gray brightred brightgreen yellow brightblue brightmagenta brightcyan white）。
# 注意：newt 的 white＝亮白、lightgray＝一般白、yellow＝亮黃；沒有 brightwhite/brightyellow/brightblack，
# 寫錯整個元素會退回預設色（例如內文區變成綠底）。背景用 bright* 色會失效，背景只用 8 個基本色。
# 按鈕：whiptail 用 compact button —— 未聚焦用 compactbutton，「聚焦中」用 button（不是 actbutton）。
# 兩者同色就看不出游標停在 Yes 還是 No（libnewt 0.52.21 實測）。
export NEWT_COLORS='
root=,black
window=white,black
border=gray,black
title=white,black
textbox=white,black
acttextbox=brightgreen,black
button=black,green
compactbutton=lightgray,black
actbutton=black,green
listbox=lightgray,black
actlistbox=black,green
sellistbox=brightgreen,black
actsellistbox=black,green
entry=white,black
disentry=gray,black
checkbox=lightgray,black
actcheckbox=black,green
helpline=white,black
roottext=white,black
emptyscale=,black
fullscale=,green
'

# === 顏色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# === Log helper ===
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# fatal: TUI 友善的致命錯誤。若 whiptail 可用且 stdin 是 TTY，先彈
# msgbox 讓使用者看清訊息（特別是 actionable 指引），再 exit 1。
# 否則退回普通 error()。
fatal() {
    local msg="$1"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        whiptail --title "❌ 致命錯誤" --scrolltext --msgbox "$msg" 18 76 2>/dev/null || true
    fi
    error "$msg"
}

# === 權限檢查 ===
require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "請使用 sudo 或 root 執行此腳本。"
    fi
}

# === .env 載入 ===
# 用法: load_env  → 從 repo 根目錄（webops/.. 的上一層）載入 .env
# 解 symlink 支援 — 即便 /usr/local/bin/xxx 是 symlink，仍能找到 repo 內 .env。
load_env() {
    local lib_dir webops_dir_path repo_dir env_file
    lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    webops_dir_path="$(dirname "$lib_dir")"
    repo_dir="$(dirname "$webops_dir_path")"
    env_file="$repo_dir/.env"

    if [ -f "$env_file" ]; then
        # 與 install_acme.sh 同樣的載入模式（保持一致性）
        export $(grep -v '^#' "$env_file" | xargs) 2>/dev/null || true
    else
        error "找不到 .env 檔案：$env_file（請複製 .env.example 並填寫）"
    fi
}

# === 取得 webops 目錄 ===
# 解 symlink，回傳 webops/ 絕對路徑（給呼叫者找 sibling 腳本與 lib/）
webops_dir() {
    local lib_dir
    lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    echo "$(dirname "$lib_dir")"
}

# === 版本 ===
# 從 webops/VERSION 讀；找不到回退 0.0.0
webops_version() {
    local vfile
    vfile="$(webops_dir)/VERSION"
    [ -f "$vfile" ] && head -n1 "$vfile" | tr -d '[:space:]' || echo "0.0.0"
}

# === 設定預設值（供下游 source 後使用） ===
# WEBOPS_BASE_DIR / WEBOPS_USERNAME / WEBOPS_SSL_PATH / WEBOPS_PHP_FPM_SOCK
# 這些變數在呼叫 load_env 後可能仍未設定，這裡套預設。
# 注意：WEBOPS_SERVER_IP 不在這裡套預設值 — 它未設定時要用網路偵測
# （見 webops_server_ips()），不是靜態常數，不適合塞進這個函式。
apply_webops_defaults() {
    : "${WEBOPS_BASE_DIR:=/home/svc-app/public_html}"
    : "${WEBOPS_USERNAME:=svc-app}"
    : "${WEBOPS_SSL_PATH:=${SSL_DIR:-/etc/nginx/ssl}}"

    if [ -z "${WEBOPS_PHP_FPM_SOCK:-}" ]; then
        # 自動偵測最新版 PHP-FPM socket
        local sock
        sock=$(ls -t /run/php/php*-fpm.sock 2>/dev/null | head -n1)
        WEBOPS_PHP_FPM_SOCK="${sock:-/run/php/php-fpm.sock}"
    fi
    export WEBOPS_BASE_DIR WEBOPS_USERNAME WEBOPS_SSL_PATH WEBOPS_PHP_FPM_SOCK
}

# === 本機公網 IP（給 cf-dns ls 過濾 / rm-sub checklist 過濾 / cf-dns add 預設值共用） ===
# 用法: webops_server_ips  → 每行一個 IP，v4/v6 皆可能出現
# 來源優先序：
#   1. .env 的 WEBOPS_SERVER_IP（逗號分隔多個，去除空白）
#   2. 自動偵測（curl ipv4.icanhazip.com，5 秒逾時）
# 失敗（未設定且偵測不到）→ 回傳非 0、不輸出任何內容；呼叫端應視為「無法過濾，顯示全部」。
# 同一次執行只打一次網路：結果快取在 _WEBOPS_SERVER_IPS_CACHE。
_WEBOPS_SERVER_IPS_CACHE=""
_WEBOPS_SERVER_IPS_CACHED=0
webops_server_ips() {
    if [ "$_WEBOPS_SERVER_IPS_CACHED" = "1" ]; then
        [ -n "$_WEBOPS_SERVER_IPS_CACHE" ] || return 1
        printf '%s\n' "$_WEBOPS_SERVER_IPS_CACHE"
        return 0
    fi
    _WEBOPS_SERVER_IPS_CACHED=1

    if [ -n "${WEBOPS_SERVER_IP:-}" ]; then
        local ips
        ips=$(echo "$WEBOPS_SERVER_IP" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
        if [ -n "$ips" ]; then
            _WEBOPS_SERVER_IPS_CACHE="$ips"
            printf '%s\n' "$ips"
            return 0
        fi
    fi

    local detected
    detected=$(curl -fsSL --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    if [ -n "$detected" ]; then
        _WEBOPS_SERVER_IPS_CACHE="$detected"
        printf '%s\n' "$detected"
        return 0
    fi

    _WEBOPS_SERVER_IPS_CACHE=""
    return 1
}
