#!/bin/bash
#
# install_ssh_hardening.sh — SSH 配置強化（Cloudflare Browser Terminal 友善）
# 用法: chmod +x install_ssh_hardening.sh && sudo ./install_ssh_hardening.sh
#
# 動作：
#   1. drop /etc/ssh/sshd_config.d/10-cloudflare-ssh-keepalive.conf
#   2. sshd -t 驗證；失敗自動 rollback（rm conf）
#   3. systemctl reload ssh（保留既有連線；不用 restart）
#
# 設定內容（純 additive，不動主 sshd_config）：
#   • Connection Keep-Alive: 5 分鐘無心跳才斷
#   • Algorithm Optimization: 限縮為 Cloudflare + 現代 OpenSSH 共通集合
#   • Rekey Protection: 1GB 或 1 小時才 rekey
#   • UseDNS no / GSSAPIAuthentication no: 縮短登入時間
#
# 移除：sudo rm /etc/ssh/sshd_config.d/10-cloudflare-ssh-keepalive.conf && sudo systemctl reload ssh
#

set -e

# === 顏色 / log ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === root 檢查 ===
[ "$EUID" -ne 0 ] && error "請使用 sudo 或 root 執行此腳本。"

# === 確認 sshd_config.d/ 可用 ===
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
if [ ! -d "$SSHD_DROPIN_DIR" ]; then
    error "找不到 $SSHD_DROPIN_DIR；此腳本需要 OpenSSH 7.3+ 與 Debian 10+ / Ubuntu 18.04+。"
fi

# 確認主 sshd_config 有 Include drop-in（Debian/Ubuntu 預設都有，保險檢查）
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    warn "主 /etc/ssh/sshd_config 沒看到 Include /etc/ssh/sshd_config.d/*.conf 指令。"
    warn "若 reload 後設定沒生效，請手動在 /etc/ssh/sshd_config 加上："
    warn "  Include /etc/ssh/sshd_config.d/*.conf"
fi

# === 寫 conf（冪等覆蓋）===
CONF="$SSHD_DROPIN_DIR/10-cloudflare-ssh-keepalive.conf"

if [ -f "$CONF" ]; then
    info "$CONF 已存在，覆蓋為標準內容..."
else
    info "建立 $CONF..."
fi

cat > "$CONF" <<'EOF'
# Managed by install_ssh_hardening.sh — 移除此檔即還原
#
# 1. Connection Keep-Alive Optimization
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 10
UseDNS no
GSSAPIAuthentication no

# 2. Algorithm Optimization (Hardened for Cloudflare Browser Terminal)
# Ensures the handshake uses algorithms supported by Cloudflare to prevent Rekey failures
KexAlgorithms curve25519-sha256@libssh.org,curve25519-sha256,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512

# 3. Rekey Protection (Critical for session stability)
# Limits key re-negotiation to every 1GB of data or 1 hour to minimize connection drops
RekeyLimit 1G 1h
EOF
chmod 644 "$CONF"

# === sshd -t 驗證；失敗自動 rollback ===
info "執行 sshd -t 驗證 config..."
SSHD_TEST_LOG=$(mktemp)
if ! sshd -t 2>"$SSHD_TEST_LOG"; then
    err=$(cat "$SSHD_TEST_LOG")
    rm -f "$SSHD_TEST_LOG" "$CONF"
    error "sshd -t 失敗（已 rollback 移除 $CONF）：\n$err"
fi
rm -f "$SSHD_TEST_LOG"
info "sshd -t 通過。"

# === 套用：reload（保留既有連線）===
# reload 送 SIGHUP 讓 sshd 主 process 重讀 config，現有連線（forked children）不受影響。
# 不用 restart — 雖然 forked children 在 systemd 模式下也會留著，但語意上 reload 更安全。
info "systemctl reload ssh..."
if systemctl reload ssh; then
    info "Reload 成功。"
elif systemctl reload sshd 2>/dev/null; then
    # 部分發行版 service 名為 sshd
    info "Reload 成功（service 名為 sshd）。"
else
    warn "reload 失敗；嘗試 restart..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    info "Restart 成功。"
fi

# === 完成 ===
echo -e "\n${GREEN}========================================${NC}"
info "🎉 SSH 配置強化完成！"
echo ""
echo -e "  ${YELLOW}Conf:${NC}     $CONF"
echo -e "  ${YELLOW}套用方式:${NC} systemctl reload ssh（既有連線不中斷）"
echo ""
echo -e "${YELLOW}驗證生效：${NC}"
echo -e "  sudo sshd -T | grep -E '^(clientaliveinterval|tcpkeepalive|usedns|rekeylimit)'"
echo ""
echo -e "${YELLOW}萬一連不上要 rollback：${NC}"
echo -e "  sudo rm $CONF"
echo -e "  sudo systemctl reload ssh"
echo -e "${GREEN}========================================${NC}\n"
