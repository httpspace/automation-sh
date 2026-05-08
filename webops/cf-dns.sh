#!/bin/bash
#
# cf-dns.sh — Cloudflare DNS 子網域 CLI
#
# 用法:
#   sudo cf-dns add <prefix> <main-domain> [ip]
#   sudo cf-dns rm  <fqdn-or-prefix.main>
#   sudo cf-dns ls  <main-domain>
#   sudo cf-dns check <fqdn>
#
# - 主網域必須已在 webops/domains.conf 註冊
# - CF_Token 從 .env 讀（與 install_acme.sh 共用）
# - 預設 IP = 本機公網 IP（curl ipv4.icanhazip.com）
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/domains.sh
source "$LIB_DIR/domains.sh"

require_root
load_env

if [ -z "${CF_Token:-}" ]; then
    error ".env 中缺少 CF_Token（請先設定，與 install_acme.sh 共用）"
fi

command -v jq   >/dev/null 2>&1 || error "需要 jq；請執行 sudo apt-get install -y jq"
command -v curl >/dev/null 2>&1 || error "需要 curl"

CF_API="https://api.cloudflare.com/client/v4"

usage() {
    cat <<USAGE
用法:
  sudo cf-dns add <prefix> <main-domain> [ip]
  sudo cf-dns rm  <fqdn>
  sudo cf-dns ls  <main-domain>
  sudo cf-dns check <fqdn>
USAGE
    exit 1
}

# === 工具：檢查回傳 ===
cf_check_success() {
    local resp="$1"
    if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
        local msg
        msg=$(echo "$resp" | jq -r '.errors[0].message // "未知錯誤"')
        error "Cloudflare API 失敗：$msg"
    fi
}

cmd_add() {
    local prefix="$1" main="$2" ip="${3:-}"
    [ -z "$main" ] && usage
    # prefix 可空（或 @）→ 表示主網域 apex 本身

    # 子網域前綴驗證：DNS label 規則（RFC 1035 簡化版）
    # 允許 a-z A-Z 0-9 . -；不能以 - 或 . 開頭結尾；可有多段（lab.dev）
    if [ -n "$prefix" ] && [ "$prefix" != "@" ]; then
        if ! [[ "$prefix" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            error "子網域前綴格式無效：「$prefix」

允許字元：英數字、- 與 .
不能以 - 或 . 開頭/結尾（DNS label 規則）

合法範例：lab、my-story、dev.api、a1b2"
        fi
    fi

    local zone_id
    zone_id=$(domains_resolve_zone_id "$main") \
        || error "找不到 $main 的 zone_id（請確認已在 domains.conf 註冊，且 token 有 Zone:Zone:Read 可 auto-discover）"

    if [ -z "$ip" ]; then
        ip=$(curl -fsSL http://ipv4.icanhazip.com)
    fi

    # 推導 FQDN 與 CF API 用的 name 欄位（apex 用主網域全名最穩）
    local fqdn cf_name
    if [ -z "$prefix" ] || [ "$prefix" = "@" ]; then
        fqdn="$main"
        cf_name="$main"
    else
        fqdn="$prefix.$main"
        cf_name="$prefix"
    fi

    info "正在新增 $fqdn → $ip（zone: $zone_id）"

    local resp
    resp=$(curl -fsSL -X POST "$CF_API/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $CF_Token" \
        -H "Content-Type: application/json" \
        --data "$(jq -n --arg n "$cf_name" --arg c "$ip" \
            '{type:"A", name:$n, content:$c, ttl:1, proxied:true}')")

    cf_check_success "$resp"
    info "✅ $fqdn 已建立。"
}

cmd_rm() {
    local fqdn="$1"
    [ -z "$fqdn" ] && usage

    local main
    main=$(domains_resolve_main "$fqdn") || error "無法從 $fqdn 推導主網域；請確認 webops/domains.conf 已註冊"

    local zone_id
    zone_id=$(domains_resolve_zone_id "$main") \
        || error "找不到 $main 的 zone_id"

    info "正在查詢 $fqdn 在 zone $main 的記錄 ID..."
    local resp
    resp=$(curl -fsSL -G "$CF_API/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $CF_Token" \
        --data-urlencode "name=$fqdn")
    cf_check_success "$resp"

    local count
    count=$(echo "$resp" | jq -r '.result | length')
    [ "$count" = "0" ] && error "找不到 $fqdn 的 DNS 記錄"

    # 用 mapfile 把記錄抓進 array，避免 pipe + while 讓 error/exit 困在 subshell
    mapfile -t records < <(echo "$resp" | jq -r '.result[] | "\(.id)\t\(.type)\t\(.content)"')
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r rid rtype rcontent <<< "$rec"
        info "刪除 $fqdn ($rtype → $rcontent, id=$rid)"
        local del
        del=$(curl -fsSL -X DELETE "$CF_API/zones/$zone_id/dns_records/$rid" \
            -H "Authorization: Bearer $CF_Token")
        cf_check_success "$del"
    done
    info "✅ 完成。"
}

cmd_ls() {
    local main="$1"
    [ -z "$main" ] && usage

    local zone_id
    zone_id=$(domains_resolve_zone_id "$main") \
        || error "找不到 $main 的 zone_id"

    local resp
    resp=$(curl -fsSL -G "$CF_API/zones/$zone_id/dns_records?per_page=100" \
        -H "Authorization: Bearer $CF_Token")
    cf_check_success "$resp"

    printf "%-40s %-6s %-30s %s\n" "NAME" "TYPE" "CONTENT" "PROXIED"
    echo "-----------------------------------------------------------------------------------------"
    echo "$resp" | jq -r '.result[] | "\(.name)\t\(.type)\t\(.content)\t\(.proxied)"' \
        | while IFS=$'\t' read -r name type content proxied; do
            printf "%-40s %-6s %-30s %s\n" "$name" "$type" "$content" "$proxied"
        done
}

cmd_check() {
    local fqdn="$1"
    [ -z "$fqdn" ] && usage

    local main
    main=$(domains_resolve_main "$fqdn") || error "無法從 $fqdn 推導主網域"
    local zone_id
    zone_id=$(domains_resolve_zone_id "$main") \
        || error "找不到 $main 的 zone_id"

    local resp
    resp=$(curl -fsSL -G "$CF_API/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $CF_Token" \
        --data-urlencode "name=$fqdn")
    cf_check_success "$resp"

    local count
    count=$(echo "$resp" | jq -r '.result | length')
    if [ "$count" = "0" ]; then
        warn "$fqdn 不存在於 Cloudflare（zone: $main）"
        exit 1
    fi
    info "$fqdn 存在 $count 筆記錄："
    echo "$resp" | jq -r '.result[] | "  \(.type)  →  \(.content)  (proxied=\(.proxied))"'
}

case "${1:-}" in
    add)   shift; cmd_add   "$@" ;;
    rm)    shift; cmd_rm    "$@" ;;
    ls)    shift; cmd_ls    "$@" ;;
    check) shift; cmd_check "$@" ;;
    *)     usage ;;
esac
