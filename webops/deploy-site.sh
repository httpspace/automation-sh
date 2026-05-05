#!/bin/bash
#
# deploy-site.sh — Nginx vhost 部署工具（多模式 + 多主網域）
#
# 用法:
#   sudo deploy-site                                  # TUI 互動模式
#   sudo deploy-site <fqdn> <mode> [port] [user]      # 直接呼叫
#
# mode: php | laravel | hybrid | python
# port: hybrid 預設 3000、python 預設 8000、php/laravel 不需
# user: 部署目標帳號；省略則用 .env 的 WEBOPS_USERNAME（預設 svc-app）
#       base dir 推導為 /home/<user>/public_html
#       帳號必須由管理員預先建立並設定權限（useradd + groupadd www-data 等）
#
# 設定來源（.env）:
#   WEBOPS_BASE_DIR     預設站點根目錄（/home/svc-app/public_html）
#   WEBOPS_USERNAME     預設站點檔案 owner（svc-app）
#   WEBOPS_SSL_PATH     SSL 憑證路徑（預設 = $SSL_DIR 或 /etc/nginx/ssl）
#   WEBOPS_PHP_FPM_SOCK PHP-FPM socket（自動偵測）
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"
# shellcheck source=lib/domains.sh
source "$LIB_DIR/domains.sh"

require_root
load_env
apply_webops_defaults

INPUT_DOMAIN="${1:-}"
MODE="${2:-}"
PORT_ARG="${3:-}"
USER_ARG="${4:-}"

# === 1. 取得 FQDN ===
if [ -z "$INPUT_DOMAIN" ]; then
    # 互動模式：選主網域 → 輸入子網域
    if ! tui_available; then
        error "需要 whiptail（apt install whiptail）或改用 sudo deploy-site <fqdn> <mode> [port]"
    fi
    domains_require_conf
    MAIN=$(tui_pick_domain) || exit 0
    SUB=$(tui_input "子網域前綴（例如 lab）；留空 = 部署主網域 $MAIN 本身" "") || exit 0
    if [ -z "$SUB" ] || [ "$SUB" = "@" ]; then
        DOMAIN="$MAIN"
    else
        DOMAIN="$SUB.$MAIN"
    fi
else
    DOMAIN="$INPUT_DOMAIN"
fi

# 驗證 FQDN 字元集
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    error "網域格式無效：$DOMAIN"
fi

# === 2. 推導主網域與 SSL 憑證 ===
ROOT_DOMAIN=""
if domains_resolve_main "$DOMAIN" >/dev/null 2>&1; then
    ROOT_DOMAIN=$(domains_resolve_main "$DOMAIN")
else
    # 退而求其次：取最後兩段
    ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{ print $(NF-1)"."$NF }')
    warn "$DOMAIN 對應的主網域未在 domains.conf 註冊；使用 $ROOT_DOMAIN"
fi

CRT="$WEBOPS_SSL_PATH/$ROOT_DOMAIN.crt"
KEY="$WEBOPS_SSL_PATH/$ROOT_DOMAIN.key"

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
    error "找不到 $ROOT_DOMAIN 的 SSL 憑證（$CRT / $KEY）；請先 sudo ./install_wildcard_ssl.sh $ROOT_DOMAIN"
fi

# === 3. 取得 Mode ===
if [ -z "$MODE" ]; then
    if tui_available; then
        MODE=$(tui_menu "選擇部署模式" \
            "php"     "純 PHP 站點" \
            "laravel" "Laravel（public/ 為根）" \
            "hybrid"  "前後端分離（前端 proxy + /api Laravel）" \
            "python"  "Python（proxy 到後端 port）") || exit 0
    else
        error "未指定 mode；請用 sudo deploy-site <fqdn> <mode> [port]"
    fi
fi

case "$MODE" in
    php|laravel|hybrid|python) ;;
    *) error "無效 mode: $MODE（php|laravel|hybrid|python）" ;;
esac

# === 4. 取得 Port ===
PORT="-"
if [ "$MODE" = "hybrid" ] || [ "$MODE" = "python" ]; then
    local_default=3000
    [ "$MODE" = "python" ] && local_default=8000
    if [ -z "$PORT_ARG" ]; then
        if tui_available; then
            PORT=$(tui_input "後端應用 Port" "$local_default") || exit 0
        else
            PORT="$local_default"
        fi
    else
        PORT="$PORT_ARG"
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        error "Port 需為數字：$PORT"
    fi
fi

# === 4.5. 取得目標帳號與 base dir（per-deploy 覆寫）===
# 預設用 .env 的 WEBOPS_USERNAME / WEBOPS_BASE_DIR；可在 TUI 改、或 CLI 第 4 個位置參數指定 user。
# 若指定非預設 user，base dir 自動推導為 /home/<user>/public_html。
TARGET_USER="$WEBOPS_USERNAME"
TARGET_BASE="$WEBOPS_BASE_DIR"

if [ -n "$USER_ARG" ]; then
    TARGET_USER="$USER_ARG"
    TARGET_BASE="/home/$TARGET_USER/public_html"
elif [ -z "$INPUT_DOMAIN" ]; then
    # TUI 模式：詢問是否用預設，或指定其他帳號
    if ! tui_yesno "部署目標：\n  帳號 = $WEBOPS_USERNAME\n  base = $WEBOPS_BASE_DIR\n\n用此預設？\n（選否可指定其他帳號 / base dir）"; then
        TARGET_USER=$(tui_input "部署目標帳號（系統 user）" "$WEBOPS_USERNAME") || exit 0
        [ -z "$TARGET_USER" ] && error "未輸入帳號"
        DEFAULT_BASE="/home/$TARGET_USER/public_html"
        TARGET_BASE=$(tui_input "部署目標 base dir" "$DEFAULT_BASE") || exit 0
        [ -z "$TARGET_BASE" ] && TARGET_BASE="$DEFAULT_BASE"
    fi
fi

# 驗證帳號存在（管理員必須先建立）
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    error "系統帳號 '$TARGET_USER' 不存在。\n請先由管理員建立並設定權限，例如：\n  sudo useradd -m -s /bin/bash $TARGET_USER\n  sudo usermod -aG www-data $TARGET_USER\n  sudo mkdir -p $TARGET_BASE && sudo chown $TARGET_USER:www-data $TARGET_BASE"
fi

# 驗證 base dir 父目錄存在（base dir 本身可由本腳本建立）
TARGET_BASE_PARENT=$(dirname "$TARGET_BASE")
if [ ! -d "$TARGET_BASE_PARENT" ]; then
    error "父目錄 '$TARGET_BASE_PARENT' 不存在。\n請先由管理員建立並設定 $TARGET_USER 權限。"
fi

# 若 base dir 不存在，建立它（owner = TARGET_USER，這樣後續站點目錄才繼承權限）
if [ ! -d "$TARGET_BASE" ]; then
    info "建立 base dir：$TARGET_BASE（owner=$TARGET_USER:www-data）"
    mkdir -p "$TARGET_BASE"
    chown "$TARGET_USER:www-data" "$TARGET_BASE"
    chmod 755 "$TARGET_BASE"
fi

# === 5. 既有 conf 處理（自動備份）===
CONF_DIR="/etc/nginx/conf.d"
CONF_FILE="$CONF_DIR/$DOMAIN.conf"
BAK_DIR="$CONF_DIR/.bak"

if [ -f "$CONF_FILE" ]; then
    if tui_available; then
        tui_yesno "$CONF_FILE 已存在。\n要備份後覆蓋嗎？\n（舊檔會移到 $BAK_DIR/）" || { info "已取消"; exit 0; }
    else
        warn "$CONF_FILE 已存在，將自動備份後覆蓋"
    fi
    mkdir -p "$BAK_DIR"
    cp -p "$CONF_FILE" "$BAK_DIR/$DOMAIN.conf.$(date +%Y%m%d%H%M%S)"
    info "舊檔已備份"
fi

# === 6. 建立站點目錄（已存在則跳過 — 向前相容）===
WEB_ROOT="$TARGET_BASE/$DOMAIN"

if [ ! -d "$WEB_ROOT" ]; then
    info "建立站點目錄：$WEB_ROOT"
    case "$MODE" in
        hybrid)  mkdir -p "$WEB_ROOT/frontend" "$WEB_ROOT/backend/public" ;;
        laravel) mkdir -p "$WEB_ROOT/public" ;;
        php|python) mkdir -p "$WEB_ROOT" ;;
    esac
else
    info "站點目錄已存在：$WEB_ROOT（跳過建立）"
fi
chown -R "$TARGET_USER:www-data" "$WEB_ROOT"
chmod 755 "$WEB_ROOT"

# === 7. 生成 vhost 設定 ===
SAFE_BLOCK="
    server_tokens off;
    client_max_body_size 100M;
    autoindex off;
    add_header X-Frame-Options \"SAMEORIGIN\";
    add_header X-XSS-Protection \"1; mode=block\";
    add_header X-Content-Type-Options \"nosniff\";
    location ~ /\\.(?!well-known).* { deny all; access_log off; log_not_found off; }
    location ~ \\.(bak|config|sql|log|sh|env|swp)\$ { deny all; access_log off; log_not_found off; }"

case "$MODE" in
    hybrid)
        PROJECT_CONFIG="
    index index.php index.html;
    $SAFE_BLOCK
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }
    location /api {
        alias $WEB_ROOT/backend/public;
        try_files \$uri \$uri/ @laravel;
        location ~ \\.php\$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $WEB_ROOT/backend/public/index.php;
            fastcgi_pass unix:$WEBOPS_PHP_FPM_SOCK;
        }
    }
    location @laravel { rewrite /api/(.*)\$ /api/index.php?/\$1 last; }"
        ;;
    laravel|php)
        ROOT_PATH="$WEB_ROOT"
        [ "$MODE" = "laravel" ] && ROOT_PATH="$WEB_ROOT/public"
        PROJECT_CONFIG="
    root $ROOT_PATH;
    index index.php index.html;
    $SAFE_BLOCK
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \\.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$WEBOPS_PHP_FPM_SOCK;
    }"
        ;;
    python)
        PROJECT_CONFIG="
    index index.html;
    $SAFE_BLOCK
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }"
        ;;
esac

cat > "$CONF_FILE" <<EOF
# [webops-managed]
# [Mode: $MODE]
# [Port: $PORT]
# [Date: $(date +%F)]

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    $PROJECT_CONFIG

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
}
EOF
chmod 644 "$CONF_FILE"

# === 8. 套用 ===
info "測試 Nginx 設定..."
if nginx -t; then
    systemctl reload nginx
    info "✅ 部署完成：$DOMAIN（$MODE${PORT:+, port $PORT}）"
    info "   web_root = $WEB_ROOT  (owner=$TARGET_USER:www-data)"
else
    error "nginx -t 失敗；conf 已寫入但未 reload — 請檢查 $CONF_FILE"
fi
