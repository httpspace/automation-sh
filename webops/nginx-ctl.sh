#!/bin/bash
#
# nginx-ctl.sh — Nginx 快速控制工具
# 用法: sudo nginx-ctl {reload|restart|test}
#
set -e

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

require_root

case "${1:-}" in
    reload)
        info "檢查 Nginx 設定..."
        nginx -t
        systemctl reload nginx
        info "Nginx 已成功重新載入。"
        ;;
    restart)
        info "檢查 Nginx 設定..."
        nginx -t
        systemctl restart nginx
        info "Nginx 已成功重啟。"
        ;;
    test)
        nginx -t
        ;;
    *)
        echo "用法: sudo nginx-ctl {reload|restart|test}"
        exit 1
        ;;
esac
