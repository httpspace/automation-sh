#!/bin/bash
#
# install_webops.sh — 安裝 webops 部署框架
# 用法: chmod +x install_webops.sh && sudo ./install_webops.sh
#
# 動作：
#   1. 安裝 whiptail / jq 依賴
#   2. chmod +x webops/*.sh、webops/lib/*.sh
#   3. 建立 /usr/local/bin/ 下 7 個 symlink
#   4. 若 webops/domains.conf 不存在，引導使用者建立第一筆
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBOPS_DIR="$SCRIPT_DIR/webops"

# === 顏色 / log（與 install_acme.sh 一致風格）===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === 檢查 root ===
[ "$EUID" -ne 0 ] && error "請使用 sudo 或 root 執行。"

# === 檢查 webops/ 存在 ===
[ -d "$WEBOPS_DIR" ] || error "找不到 $WEBOPS_DIR；請從正確的 repo 根目錄執行。"

# === 1. 安裝依賴 ===
info "更新套件並安裝 whiptail / jq / curl..."
apt-get update -qq
apt-get install -y -qq whiptail jq curl > /dev/null 2>&1
info "依賴安裝完成。"

# === 2. 設定執行權限 ===
info "設定 webops 腳本執行權限..."
chmod +x "$WEBOPS_DIR"/*.sh
chmod +x "$WEBOPS_DIR/lib"/*.sh 2>/dev/null || true

# === 3. 建立 symlink ===
declare -A LINKS=(
    [webops]="webops.sh"
    [domain-mgr]="domain-mgr.sh"
    [cf-dns]="cf-dns.sh"
    [deploy-site]="deploy-site.sh"
    [site-mgr]="site-mgr.sh"
    [laravel-svc]="laravel-svc.sh"
    [nginx-ctl]="nginx-ctl.sh"
)

info "建立 /usr/local/bin/ symlink..."
for name in "${!LINKS[@]}"; do
    target="$WEBOPS_DIR/${LINKS[$name]}"
    link="/usr/local/bin/$name"
    ln -sf "$target" "$link"
    info "  $link → $target"
done

# === 4. 引導建立 domains.conf ===
DOMAINS_CONF="$WEBOPS_DIR/domains.conf"
if [ ! -f "$DOMAINS_CONF" ]; then
    info "尚未建立 webops/domains.conf — 引導加入第一個主網域"

    if whiptail --title "webops 安裝" --yesno \
        "現在加入第一個主網域到註冊表嗎？\n\n（建議填入此機線上既有的主網域，向前相容）" 12 70; then

        DOMAIN=$(whiptail --title "主網域" --inputbox "主網域（例如 example.com）" 10 60 "" 3>&1 1>&2 2>&3) || DOMAIN=""
        if [ -n "$DOMAIN" ]; then
            ZID=$(whiptail --title "Cloudflare zone_id（選填）" --inputbox \
                "Cloudflare zone_id（可留空）\n\n• 留空 = webops 會用 CF_Token auto-discover（需 Zone:Zone:Read 權限）\n• 填入 = 手動指定，token 只需 Zone:DNS:Edit\n\n手動取得：CF dashboard → 該 zone → Overview → 右下 API 區塊 → Zone ID" \
                15 76 "" 3>&1 1>&2 2>&3) || ZID=""
            NOTE=$(whiptail --title "備註" --inputbox "備註（用途，可空白）" 10 60 "主站" 3>&1 1>&2 2>&3) || NOTE=""

            {
                printf '# webops 主網域註冊表（gitignore）\n'
                printf '# 格式: <domain>\\t<zone_id>\\t<note>     zone_id 可留空（auto-discover）\n'
                printf '# domain\tzone_id\tnote\n'
                printf '%s\t%s\t%s\n' "$DOMAIN" "$ZID" "$NOTE"
            } > "$DOMAINS_CONF"
            chmod 600 "$DOMAINS_CONF"

            if [ -n "$ZID" ]; then
                info "✅ 已建立 $DOMAINS_CONF（$DOMAIN，zone_id 顯式設定）"
            else
                info "✅ 已建立 $DOMAINS_CONF（$DOMAIN，zone_id 將 auto-discover）"
            fi
        else
            warn "未輸入主網域；跳過。"
        fi
    else
        warn "略過建立 domains.conf；可隨時 sudo domain-mgr 加入。"
    fi
else
    info "已存在 $DOMAINS_CONF — 保留不動"
fi

# === 5. 完成 ===
echo -e "\n${GREEN}========================================${NC}"
info "🎉 webops 安裝完成！"
echo ""
echo -e "  入口：${YELLOW}sudo webops${NC}"
echo -e "  文件：${YELLOW}README.md${NC} 或 ${YELLOW}sudo webops${NC} → 網域總覽"
echo ""
echo -e "  其他 CLI 直呼："
echo -e "    sudo cf-dns add <prefix> <main-domain>"
echo -e "    sudo deploy-site <fqdn> <mode> [port]"
echo -e "    sudo site-mgr / sudo laravel-svc / sudo nginx-ctl"
echo -e "${GREEN}========================================${NC}\n"
