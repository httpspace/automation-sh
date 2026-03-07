#!/bin/bash
#
# install_acme.sh — 安裝 acme.sh + 自動讀取 .env 設定
# 用法: chmod +x install_acme.sh && sudo ./install_acme.sh
#

set -e

# === 顏色設定 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# === 檢查 Root 權限 ===
if [ "$EUID" -ne 0 ]; then
  error "請使用 sudo 或 root 權限執行此腳本。"
fi

# === 1. 載入 .env 檔案 ===
# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    info "偵測到 .env 檔案，正在載入設定..."
    # 讀取 .env 檔案並匯入環境變數 (排除註解與空行)
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    error "找不到 .env 檔案！請先將 .env.example 複製為 .env 並填入資訊。"
fi

# 驗證必要變數
if [ -z "$ACME_EMAIL" ] || [ -z "$CF_Token" ]; then
    error ".env 檔案中的 ACME_EMAIL 或 CF_Token 不能為空。"
fi

# === 2. 安裝依賴套件 ===
info "更新系統並安裝必要套件 (curl, cron, socat)..."
apt-get update -qq
apt-get install -y -qq curl cron socat > /dev/null 2>&1
info "套件安裝完成。"

# === 3. 安裝 acme.sh ===
info "開始安裝 acme.sh..."
# 安裝在 /root/.acme.sh
curl https://get.acme.sh | sh -s email="$ACME_EMAIL"

# 設定 acme.sh 指令路徑
export HOME=/root
ACME="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
    error "acme.sh 安裝失敗，請檢查網路連線。"
fi

# === 4. 設定預設 CA 為 Let's Encrypt ===
info "設定預設 CA 為 Let's Encrypt..."
"$ACME" --set-default-ca --server letsencrypt

# === 5. 寫入 Cloudflare Token ===
info "正在將 Cloudflare Token 寫入 acme.sh 設定檔..."
ACME_ACCOUNT_CONF="$HOME/.acme.sh/account.conf"

# 檢查是否已有設定，有則更新，無則新增
if grep -q "SAVED_CF_Token" "$ACME_ACCOUNT_CONF" 2>/dev/null; then
    sed -i "s|SAVED_CF_Token=.*|SAVED_CF_Token='$CF_Token'|" "$ACME_ACCOUNT_CONF"
else
    echo "SAVED_CF_Token='$CF_Token'" >> "$ACME_ACCOUNT_CONF"
fi
info "CF_Token 已安全存入 $ACME_ACCOUNT_CONF"

# === 6. 確認 Cron 自動續期 ===
if crontab -l 2>/dev/null | grep -q "acme.sh"; then
    info "✅ 自動續期排程 (cron) 已成功設定。"
else
    warn "未偵測到自動續期排程，嘗試手動安裝..."
    "$ACME" --install-cronjob
fi

echo -e "\n${GREEN}========================================${NC}"
info "恭喜！acme.sh 安裝與 Cloudflare 設定完成！"
info "您現在可以開始申請證書了，例如："
info "acme.sh --issue --dns dns_cf -d example.com -d *.example.com"
echo -e "${GREEN}========================================${NC}\n"  