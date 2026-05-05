#!/bin/bash
# webops/lib/domains.sh — domains.conf 主網域註冊表解析
# 此檔案僅供 source，不直接執行。
#
# domains.conf 格式：每行一筆主網域，欄位用 TAB 分隔，'#' 為註解。
#   <domain>\t<zone_id>\t<note>
#
# 例：
#   example.com    abcdef1234567890abcdef1234567890    主站
#
# 解析時：用 awk 切 TAB；空白行與 # 開頭跳過。

# 取得 domains.conf 路徑
domains_conf_path() {
    local lib_dir
    lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    echo "$(dirname "$lib_dir")/domains.conf"
}

# zone_id 快取檔（auto-discover 後存這裡，避免每次打 CF API）
domains_zone_cache_path() {
    local lib_dir
    lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    echo "$(dirname "$lib_dir")/.zone-cache"
}

# 確認 domains.conf 存在；不存在則 error
domains_require_conf() {
    local f
    f="$(domains_conf_path)"
    if [ ! -f "$f" ]; then
        error "尚未建立 webops/domains.conf；請執行 sudo install_webops.sh 或手動建立。"
    fi
}

# 列出所有主網域名稱（每行一個）
domains_list_names() {
    local f
    f="$(domains_conf_path)"
    [ -f "$f" ] || return 0
    awk -F'\t' '!/^#/ && NF>=2 && $1!="" { print $1 }' "$f"
}

# 取得指定 domain 在 domains.conf 內顯式設定的 zone_id（可能空）
domains_get_zone_id() {
    local domain="$1" f
    f="$(domains_conf_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v d="$domain" '!/^#/ && $1==d { print $2; exit }' "$f"
}

# 取得指定 domain 的 note
domains_get_note() {
    local domain="$1" f
    f="$(domains_conf_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v d="$domain" '!/^#/ && $1==d { print $3; exit }' "$f"
}

# 檢查 domain 是否已在 domains.conf 註冊（zone_id 可空）
domains_exists() {
    local domain="$1" f
    f="$(domains_conf_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v d="$domain" '!/^#/ && $1==d { found=1 } END { exit !found }' "$f"
}

# 從 cache 讀 zone_id（不打 API）
domains_get_zone_id_cached() {
    local domain="$1" f
    f="$(domains_zone_cache_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v d="$domain" '$1==d { print $2; exit }' "$f"
}

# 解析 zone_id：先 domains.conf → cache → CF API auto-discover（並寫入 cache）
# 用法: zid=$(domains_resolve_zone_id "example.com")
# 失敗（找不到 / 沒 token / API 失敗）回傳 1，stdout 空。
domains_resolve_zone_id() {
    local domain="$1"
    [ -z "$domain" ] && return 1

    # 1. domains.conf 顯式設定優先
    local zid
    zid=$(domains_get_zone_id "$domain")
    if [ -n "$zid" ]; then
        echo "$zid"
        return 0
    fi

    # 2. 本機 cache
    zid=$(domains_get_zone_id_cached "$domain") || true
    if [ -n "$zid" ]; then
        echo "$zid"
        return 0
    fi

    # 3. CF API auto-discover（需 Zone:Zone:Read 權限）
    if [ -z "${CF_Token:-}" ]; then
        return 1
    fi
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1

    local resp
    resp=$(curl -fsSL -G "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $CF_Token" \
        --data-urlencode "name=$domain" 2>/dev/null) || return 1

    if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
        return 1
    fi

    zid=$(echo "$resp" | jq -r '.result[0].id // empty')
    if [ -z "$zid" ] || [ "$zid" = "null" ]; then
        return 1
    fi

    # 寫入 cache
    local cache
    cache="$(domains_zone_cache_path)"
    if [ ! -f "$cache" ]; then
        printf '# webops zone_id 快取（gitignore；auto-discover 結果）\n' > "$cache"
        chmod 600 "$cache"
    fi
    printf '%s\t%s\n' "$domain" "$zid" >> "$cache"

    echo "$zid"
    return 0
}

# 新增主網域
# 用法: domains_add <domain> [zone_id] [note]
# zone_id 可空字串（之後由 domains_resolve_zone_id 從 CF API auto-discover）
domains_add() {
    local domain="$1" zone_id="${2:-}" note="${3:-}" f
    f="$(domains_conf_path)"

    if [ -z "$domain" ]; then
        error "domains_add 需要 domain"
    fi
    if domains_exists "$domain"; then
        error "domain $domain 已存在於 domains.conf"
    fi

    # 確保檔案存在 + 標頭
    if [ ! -f "$f" ]; then
        {
            printf '# webops 主網域註冊表（gitignore）\n'
            printf '# 格式: <domain>\\t<zone_id>\\t<note>     zone_id 可留空（auto-discover）\n'
            printf '# domain\tzone_id\tnote\n'
        } > "$f"
        chmod 600 "$f"
    fi

    printf '%s\t%s\t%s\n' "$domain" "$zone_id" "$note" >> "$f"
}

# 移除主網域
# 用法: domains_remove <domain>
domains_remove() {
    local domain="$1" f tmp
    f="$(domains_conf_path)"
    [ -f "$f" ] || error "domains.conf 不存在"

    tmp=$(mktemp)
    awk -F'\t' -v d="$domain" '$1==d { next } { print }' "$f" > "$tmp"
    mv "$tmp" "$f"
    chmod 600 "$f"
}

# 從完整網域字串推導對應的主網域（取最長後綴匹配）
# 用法: main=$(domains_resolve_main "lab.example.com") → "example.com"
# 找不到回傳空字串，return 1
domains_resolve_main() {
    local fqdn="$1" f best=""
    f="$(domains_conf_path)"
    [ -f "$f" ] || return 1

    while IFS= read -r main; do
        [ -z "$main" ] && continue
        # 完整等同或結尾為 .main
        if [ "$fqdn" = "$main" ] || [[ "$fqdn" == *".$main" ]]; then
            # 取最長匹配
            if [ ${#main} -gt ${#best} ]; then
                best="$main"
            fi
        fi
    done < <(domains_list_names)

    if [ -n "$best" ]; then
        echo "$best"
        return 0
    fi
    return 1
}
