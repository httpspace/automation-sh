#!/bin/bash
# webops/lib/common.sh — 共用 helper：顏色、log、權限、.env 載入
# 此檔案僅供 source，不直接執行。

# === whiptail 暗色主題（被 source 後自動套用全部 webops 對話框） ===
export NEWT_COLORS='
root=,black
window=brightwhite,black
border=brightcyan,black
title=brightyellow,black
textbox=brightwhite,black
button=black,brightcyan
actbutton=brightwhite,blue
listbox=brightwhite,black
actlistbox=black,brightcyan
sellistbox=black,brightcyan
actsellistbox=brightwhite,blue
entry=brightwhite,black
checkbox=brightwhite,black
actcheckbox=black,brightcyan
helpline=brightwhite,black
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
