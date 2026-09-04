#!/bin/bash
# webops/lib/cf.sh — Cloudflare DNS API 共用 helper
# 此檔案僅供 source（被 cf-dns.sh / advanced.sh 使用），不直接執行。
# 依賴：呼叫前需已 source common.sh（用到 error()）、已 load_env（用到 CF_Token）。

CF_API="https://api.cloudflare.com/client/v4"

# Cloudflare DNS records list 的 per_page。官方文件未公開硬上限（過大只會
# timeout），正規做法是搭配 result_info.total_pages 翻頁抓完整份清單。
CF_DNS_PER_PAGE=100

# === 工具：檢查回傳 ===
# 用法: cf_check_success "$resp"  → success != true 時印錯誤並 exit
cf_check_success() {
    local resp="$1"
    if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
        local msg
        msg=$(echo "$resp" | jq -r '.errors[0].message // "未知錯誤"')
        error "Cloudflare API 失敗：$msg"
    fi
}

# === 取得 zone 內全部 DNS 記錄（自動翻頁抓完整份） ===
# 用法: resp=$(cf_list_records "$zone_id")
# 每頁 CF_DNS_PER_PAGE 筆，依 result_info.total_pages 迴圈到抓完；任一頁失敗
# 就整個中止（cf_check_success 會 error/exit，不會吐出半成品 JSON）。
# 上限保護：total_pages > 50 時只抓前 50 頁並 warn 一聲，避免異常無限迴圈。
cf_list_records() {
    local zone_id="$1"
    local page=1 total_pages
    local -a pages_json=()
    local resp

    resp=$(curl -fsSL -G "$CF_API/zones/$zone_id/dns_records" \
        --data-urlencode "per_page=$CF_DNS_PER_PAGE" \
        --data-urlencode "page=$page" \
        -H "Authorization: Bearer $CF_Token") || return 1
    cf_check_success "$resp"
    pages_json+=("$resp")

    total_pages=$(echo "$resp" | jq -r '.result_info.total_pages // 1')
    [[ "$total_pages" =~ ^[0-9]+$ ]] || total_pages=1
    if [ "$total_pages" -gt 50 ]; then
        warn "zone 記錄分頁數 $total_pages 超過上限，只抓前 50 頁"
        total_pages=50
    fi

    for ((page = 2; page <= total_pages; page++)); do
        resp=$(curl -fsSL -G "$CF_API/zones/$zone_id/dns_records" \
            --data-urlencode "per_page=$CF_DNS_PER_PAGE" \
            --data-urlencode "page=$page" \
            -H "Authorization: Bearer $CF_Token") || return 1
        cf_check_success "$resp"
        pages_json+=("$resp")
    done

    printf '%s\n' "${pages_json[@]}" | jq -s '{success: true, result: (map(.result) | add // [])}'
}

# === 過濾出「屬於本機」的記錄 ===
# 用法: cf_filter_host_records "$json" [ip]...
# 規則：
#   - A/AAAA 且 content 在給定 IP 集合 → 保留
#   - CNAME 且 content 等於上面保留記錄的 name → 保留（一層）
#   - 其餘捨棄
# IP 參數 0 個 → 原樣輸出（給「顯示全部」與 IP 偵測失敗時共用）。
# 輸出維持 {success:true, result:[...]} 結構。
cf_filter_host_records() {
    local json="$1"; shift
    if [ "$#" -eq 0 ]; then
        printf '%s' "$json"
        return 0
    fi
    local ips_json out rc
    ips_json=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 1
    out=$(echo "$json" | jq --argjson ips "$ips_json" '
        (.result // []) as $all
        | ($all | map(select((.type=="A" or .type=="AAAA") and (.content as $c | $ips | index($c) != null)))) as $host
        | ($host | map(.name)) as $hostnames
        | {
            success: true,
            result: ($all | map(select(
                ((.type=="A" or .type=="AAAA") and (.content as $c | $ips | index($c) != null))
                or (.type=="CNAME" and (.content as $c | $hostnames | index($c) != null))
            )))
          }
    ')
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$out"
}

# === 記錄筆數 ===
# 用法: cf_records_count "$json"
cf_records_count() {
    echo "$1" | jq -r '.result | length'
}

# === 刪除單筆 DNS 記錄 ===
# 用法: cf_delete_record <zone_id> <record_id>
cf_delete_record() {
    local zone_id="$1" record_id="$2"
    curl -fsSL -X DELETE "$CF_API/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $CF_Token"
}
