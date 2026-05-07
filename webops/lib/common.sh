#!/bin/bash
# webops/lib/common.sh — 共用 helper：顏色、log、權限、.env 載入
# 此檔案僅供 source，不直接執行。

# === whiptail 暗色主題（被 source 後自動套用全部 webops 對話框） ===
# 只用黑底；高亮一律用 dark blue 而非 bright cyan，避免亮色系背景
export NEWT_COLORS='
root=,black
window=white,black
border=cyan,black
title=yellow,black
textbox=white,black
button=brightwhite,black
actbutton=brightwhite,blue
listbox=white,black
actlistbox=brightwhite,blue
sellistbox=brightcyan,black
actsellistbox=brightyellow,blue
entry=white,black
disentry=brightblack,black
checkbox=white,black
actcheckbox=brightwhite,blue
helpline=white,black
roottext=white,black
emptyscale=,brightblack
fullscale=,blue
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
