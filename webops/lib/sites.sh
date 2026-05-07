#!/bin/bash
# webops/lib/sites.sh — nginx 站點 conf 解析、狀態偵測、總覽渲染
# 此檔案僅供 source；假設 lib/common.sh 與 lib/domains.sh 已被 source。

CONF_DIR="${CONF_DIR:-/etc/nginx/conf.d}"

# === 標頭 / 標籤判讀 ===

# 從 conf 標頭取值（# [Key: value]）
get_tag() {
    local conf="$1" key="$2"
    grep -m1 "^# \[$key: " "$conf" 2>/dev/null | sed -E "s/^# \[$key: (.*)\]$/\1/"
}

# 是否為 webops（新）或 [EasyAI-Managed]（舊）標籤管理
is_managed() {
    grep -qE '^# \[(webops-managed|EasyAI-Managed)\]' "$1" 2>/dev/null
}

# 顯示用標籤：MANAGED（新）/ MANAGED*（舊版相容）/ MANUAL（手動配置）
managed_label() {
    local conf="$1"
    if grep -q '^# \[webops-managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED"
    elif grep -q '^# \[EasyAI-Managed\]' "$conf" 2>/dev/null; then
        echo "MANAGED*"
    else
        echo "MANUAL"
    fi
}

# 站點 runtime 狀態判讀（heuristic）
detect_status() {
    local mode="$1" port="$2"
    if [ -n "$port" ] && [ "$port" != "-" ]; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "Online($port)"
        else
            echo "Down($port)"
        fi
    elif [ "$mode" = "laravel" ]; then
        echo "Laravel"
    elif [ "$mode" = "php" ]; then
        echo "PHP"
    else
        echo "-"
    fi
}

# === 站點列表 ===

# 列出某主網域的所有子網域 conf（含 main 自身）
# 輸出格式: <domain>\t<conf-path>
list_subdomains_for() {
    local main="$1"
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null \
        | while IFS= read -r f; do
            local d
            d=$(basename "$f" .conf)
            if [ "$d" = "$main" ] || [[ "$d" == *".$main" ]]; then
                printf '%s\t%s\n' "$d" "$f"
            fi
        done
}

# 列出所有 nginx confs 全路徑
list_all_confs() {
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort
}

# === 網站一覽渲染（給 webops 主選單 overview 用） ===
render_overview() {
    local out=""
    local registered_mains
    registered_mains=$(domains_list_names)

    if [ -z "$registered_mains" ]; then
        echo -e "尚未註冊任何主網域。\n請在主選單選「加主網域」加入第一筆。"
        return
    fi

    declare -A claimed_confs=()

    while IFS= read -r main; do
        [ -z "$main" ] && continue
        local zid zid_short
        # 主動 resolve（含 cache → API auto-discover），結果寫回 cache 後續無延遲
        zid=$(domains_resolve_zone_id "$main" 2>/dev/null || true)
        if [ -n "$zid" ]; then
            zid_short="${zid:0:4}..${zid: -1}"
        else
            zid_short="? (token 缺 Zone:Read 或網路失敗)"
        fi

        out+="🌐 $main  (zone: $zid_short)\n"

        local subs
        subs=$(list_subdomains_for "$main")
        if [ -z "$subs" ]; then
            out+="   └─ （尚無子網域 nginx 設定）\n"
        else
            local lines
            lines=$(echo "$subs" | wc -l)
            local n=0
            while IFS=$'\t' read -r d f; do
                [ -z "$d" ] && continue
                claimed_confs["$f"]=1
                n=$((n+1))
                local prefix="├─"
                [ "$n" = "$lines" ] && prefix="└─"

                local label mode port status
                label=$(managed_label "$f")
                if [ "$label" != "MANUAL" ]; then
                    mode=$(get_tag "$f" "Mode")
                    port=$(get_tag "$f" "Port")
                    status=$(detect_status "$mode" "$port")
                    out+="   $prefix $d   [$label]  $mode${port:+:$port}   $status\n"
                else
                    out+="   $prefix $d   [MANUAL]  -\n"
                fi
            done <<< "$subs"
        fi
        out+="\n"
    done <<< "$registered_mains"

    local unreg=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -z "${claimed_confs[$f]:-}" ]; then
            local d label
            d=$(basename "$f" .conf)
            label=$(managed_label "$f")
            unreg+="   └─ $d   [$label]\n"
        fi
    done < <(list_all_confs)

    if [ -n "$unreg" ]; then
        out+="⚠️  未註冊（在 nginx 但不在 domains.conf）\n$unreg"
    fi

    echo -e "$out"
}
