#!/bin/bash
#
# install_wildcard_ssl.sh — 簽發並安裝萬用字元 SSL 憑證
# 用法: sudo ./install_wildcard_ssl.sh <yourdomain.com>
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
  error "請使用 sudo 或 root 執行此腳本"
fi

# === 1. 處理網域參數 ===
DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo -e "${YELLOW}用法:${NC} sudo $0 <yourdomain.com>"
    error "未提供網域參數！請重新輸入。"
fi

# === 2. 載入環境變數 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    info "正在從 .env 載入設定..."
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    error "找不到 .env 檔案！請確保已根據 .env.example 建立並填寫 CF_Token。"
fi

# 憑證路徑 (優先讀取 .env，否則預設 /etc/nginx/ssl)
SSL_DIR=${SSL_DIR:-"/etc/nginx/ssl"}

# === 3. 檢查 acme.sh 是否存在 ===
export HOME=/root
ACME="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
  error "找不到 acme.sh，請先執行 ./install_acme.sh"
fi

# === 4. 準備目錄 ===
mkdir -p "$SSL_DIR"

# === 5. 簽發萬用字元憑證 (DNS 驗證) ===
info "開始為 ${YELLOW}$DOMAIN${NC} 簽發萬用字元憑證 (*.$DOMAIN)..."
"$ACME" --issue --dns dns_cf \
  -d "$DOMAIN" \
  -d "*.$DOMAIN" \
  --ocsp-must-staple

# === 6. 安裝憑證至 Nginx 目錄 ===
KEY_FILE="$SSL_DIR/$DOMAIN.key"
CERT_FILE="$SSL_DIR/$DOMAIN.crt"

info "正在安裝憑證檔案至 $SSL_DIR ..."
"$ACME" --install-cert -d "$DOMAIN" \
  --key-file       "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd      "systemctl reload nginx || service nginx reload"

# === 7. 顯示完成資訊 ===
echo -e "\n${GREEN}========================================${NC}"
info "🎉 憑證安裝完成！"
echo ""
echo -e "  ${YELLOW}主網域:${NC} $DOMAIN"
echo -e "  ${YELLOW}憑證路徑:${NC} $CERT_FILE"
echo -e "  ${YELLOW}私鑰路徑:${NC} $KEY_FILE"
echo ""
echo -e "請在 Nginx 設定檔中引用以上路徑。"
info "acme.sh 已自動設定 cron 定期更新，無需手動維護。"
echo -e "${GREEN}========================================${NC}\n"