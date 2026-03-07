#!/bin/bash
#
# install_phpmyadmin.sh — 下載並安裝最新版 phpMyAdmin 至 /var/www/html
# 用法: chmod +x install_phpmyadmin.sh && sudo ./install_phpmyadmin.sh
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
  error "請使用 sudo 或 root 執行此腳本。"
fi

# === 安裝目錄 ===
INSTALL_DIR="/var/www/html/phpmyadmin"

# === 1. 安裝依賴套件 ===
info "更新套件列表並安裝依賴..."
apt-get update -qq
apt-get install -y -qq curl php php-mbstring php-xml php-zip unzip > /dev/null 2>&1
info "依賴套件安裝完成。"

# === 2. 取得最新版本號 ===
info "正在從 GitHub API 取得 phpMyAdmin 最新版本號..."
TAG=$(curl -fsSL "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" \
  | grep '"tag_name"' \
  | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
VERSION=$(echo "$TAG" | sed 's/^RELEASE_//;s/_/./g')

if [ -z "$VERSION" ]; then
  error "無法取得 phpMyAdmin 版本號，請確認網路連線。"
fi

info "最新版本：${YELLOW}${VERSION}${NC}"

# === 3. 下載並解壓縮 ===
TARBALL="phpMyAdmin-${VERSION}-all-languages.tar.gz"
DOWNLOAD_URL="https://files.phpmyadmin.net/phpMyAdmin/${VERSION}/${TARBALL}"
TMP_DIR=$(mktemp -d)

info "正在下載 ${TARBALL}..."
curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${TARBALL}"

info "正在解壓縮至 ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
# 將解壓縮的目錄內容移入安裝路徑（覆蓋舊版）
rm -rf "${INSTALL_DIR:?}"/*
mv "${TMP_DIR}/phpMyAdmin-${VERSION}-all-languages/"* "$INSTALL_DIR/"
rm -rf "$TMP_DIR"

# === 4. 基礎設定 ===
CONFIG_FILE="${INSTALL_DIR}/config.inc.php"
SAMPLE_FILE="${INSTALL_DIR}/config.sample.inc.php"

info "正在建立設定檔 config.inc.php..."

if [ ! -f "$SAMPLE_FILE" ]; then
  error "找不到 config.sample.inc.php，安裝可能不完整。"
fi

cp "$SAMPLE_FILE" "$CONFIG_FILE"

# 產生 32 字元隨機 blowfish_secret
BLOWFISH_SECRET=$(openssl rand -base64 32 | tr -d '\n' | head -c 32)

# 寫入 blowfish_secret
sed -i "s|\(\$cfg\['blowfish_secret'\] = \)'[^']*'|\1'${BLOWFISH_SECRET}'|" "$CONFIG_FILE"

# 設定 TempDir
if grep -q "TempDir" "$CONFIG_FILE"; then
  sed -i "s|\(\$cfg\['TempDir'\] = \)'[^']*'|\1'/var/www/html/phpmyadmin/tmp/'|" "$CONFIG_FILE"
else
  echo "\$cfg['TempDir'] = '/var/www/html/phpmyadmin/tmp/';" >> "$CONFIG_FILE"
fi

# === 5. 建立 tmp 目錄並設定權限 ===
info "建立 tmp 目錄並設定 www-data 權限..."
mkdir -p "${INSTALL_DIR}/tmp"
chown -R www-data:www-data "$INSTALL_DIR"
chmod 750 "${INSTALL_DIR}/tmp"

# === 6. 顯示完成資訊 ===
echo -e "\n${GREEN}========================================${NC}"
info "phpMyAdmin 安裝完成！"
echo ""
echo -e "  ${YELLOW}版本:${NC}       ${VERSION}"
echo -e "  ${YELLOW}安裝路徑:${NC}   ${INSTALL_DIR}"
echo -e "  ${YELLOW}設定檔:${NC}     ${CONFIG_FILE}"
echo ""
warn "後續步驟：請自行設定 Nginx server block 指向 ${INSTALL_DIR}"
warn "建議限制 phpMyAdmin 存取來源 IP，避免暴露於公開網路。"
echo -e "${GREEN}========================================${NC}\n"
