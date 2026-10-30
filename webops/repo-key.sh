#!/bin/bash
#
# repo-key.sh — GitHub Deploy Key 管理（TUI + CLI）
#
# 手動貼上模式：本腳本只產生金鑰、印出 public key 與操作指引；
# 不需要 GITHUB_PAT，不讀寫 .env。使用者自行到 GitHub repo 頁
# 「Settings → Deploy keys → Add deploy key」貼上。
#
# 命名慣例：
#   金鑰檔  /home/<ssh_user>/.ssh/keys/<alias>_ed25519（.pub 同目錄）
#   SSH alias  Host gh-<alias>（寫入 /home/<ssh_user>/.ssh/config）
#
# 用法:
#   sudo repo-key add <github-url|owner/repo> [alias] [ssh_user]
#   sudo repo-key list
#   sudo repo-key test   <alias>
#   sudo repo-key revoke <alias>
#   sudo repo-key rotate <alias>
#   sudo repo-key                       # 無參數 + whiptail 可用 → TUI 主選單
#
# 設定來源（.env，經 apply_webops_defaults）：
#   WEBOPS_USERNAME   預設 ssh_user（svc-app），每次可用參數/TUI 覆寫
#
# 登記表 webops/repo-keys.conf（TAB 分隔，gitignore）：
#   <alias>\t<owner/repo>\t<ssh_user>\t<key_path>\t<created>
#
set -e
set -o pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
WEBOPS_TUI_TITLE="webops › GitHub Deploy Key"
# shellcheck source=lib/tui.sh
source "$LIB_DIR/tui.sh"

require_root
load_env
apply_webops_defaults

command -v ssh        >/dev/null 2>&1 || error "需要 ssh（openssh-client）"
command -v ssh-keygen  >/dev/null 2>&1 || error "需要 ssh-keygen（openssh-client）"

usage() {
    cat <<USAGE
用法:
  sudo repo-key add <github-url|owner/repo> [alias] [ssh_user]
  sudo repo-key list
  sudo repo-key test   <alias>
  sudo repo-key revoke <alias>
  sudo repo-key rotate <alias>
  sudo repo-key                       # 無參數進 whiptail TUI
USAGE
}

# ============================================================
# 登記表 CRUD（webops/repo-keys.conf，仿 lib/domains.sh pattern）
# ============================================================

repo_key_conf_path() {
    echo "$(webops_dir)/repo-keys.conf"
}

repo_key_exists() {
    local alias="$1" f
    f="$(repo_key_conf_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v a="$alias" '!/^#/ && $1==a { found=1 } END { exit !found }' "$f"
}

repo_key_add() {
    local alias="$1" owner_repo="$2" ssh_user="$3" key_path="$4" created="$5" f
    f="$(repo_key_conf_path)"

    if repo_key_exists "$alias"; then
        error "repo_key_add: alias「$alias」已存在於 repo-keys.conf"
    fi

    if [ ! -f "$f" ]; then
        {
            printf '# webops GitHub deploy key 登記表（gitignore）\n'
            printf '# 格式: <alias>\\t<owner/repo>\\t<ssh_user>\\t<key_path>\\t<created>\n'
            printf '# alias\towner/repo\tssh_user\tkey_path\tcreated\n'
        } > "$f"
        chmod 600 "$f"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$alias" "$owner_repo" "$ssh_user" "$key_path" "$created" >> "$f"
}

repo_key_remove() {
    local alias="$1" f tmp
    f="$(repo_key_conf_path)"
    [ -f "$f" ] || error "repo-keys.conf 不存在"

    tmp=$(mktemp)
    awk -F'\t' -v a="$alias" '$1==a { next } { print }' "$f" > "$tmp"
    mv "$tmp" "$f"
    chmod 600 "$f"
}

repo_key_get_row() {
    local alias="$1" f
    f="$(repo_key_conf_path)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v a="$alias" '!/^#/ && $1==a { print; found=1 } END { exit !found }' "$f"
}

repo_key_list_rows() {
    local f
    f="$(repo_key_conf_path)"
    [ -f "$f" ] || return 0
    awk -F'\t' '!/^#/ && NF>=5 && $1!=""' "$f"
}

# ============================================================
# URL / alias 解析
# ============================================================

parse_owner_repo() {
    local input="$1" owner_repo=""
    if [[ "$input" =~ ^https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(\.git)?/?$ ]]; then
        owner_repo="${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(\.git)?$ ]]; then
        owner_repo="${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        owner_repo="$input"
    else
        return 1
    fi
    owner_repo="${owner_repo%.git}"
    [[ "$owner_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    echo "$owner_repo"
}

validate_alias() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# ============================================================
# SSH config marker 區塊（冪等：寫入前先刪同 marker 舊塊）
# ============================================================

remove_ssh_config_block() {
    local config_file="$1" marker_id="$2" tmp
    [ -f "$config_file" ] || return 0
    tmp=$(mktemp)
    awk -v a="$marker_id" '
        BEGIN { skip = 0 }
        $0 ~ ("^# >>> webops-managed: " a " \\(") { skip = 1; next }
        $0 ~ ("^# <<< webops-managed: " a " <<<$") { skip = 0; next }
        skip == 0 { print }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    chmod 600 "$config_file"
}

write_ssh_config_block() {
    local config_file="$1" marker_id="$2" host_name="$3" owner_repo="$4" key_path="$5"
    remove_ssh_config_block "$config_file" "$marker_id"
    {
        printf '# >>> webops-managed: %s (%s) >>>\n' "$marker_id" "$owner_repo"
        printf 'Host %s\n' "$host_name"
        printf '    HostName github.com\n'
        printf '    User git\n'
        printf '    IdentityFile %s\n' "$key_path"
        printf '    IdentitiesOnly yes\n'
        printf '# <<< webops-managed: %s <<<\n' "$marker_id"
    } >> "$config_file"
}

# ============================================================
# 可直接複製貼上的 git 指令（add / rotate 成功後與 list 均會印）
# ============================================================

print_git_commands() {
    local alias="$1" owner_repo="$2" ssh_user="$3"
    cat <<EOF

# 情境 A：全新 clone 到專案路徑
sudo -u $ssh_user git clone gh-$alias:$owner_repo.git <目標路徑>

# 情境 B：既有專案切換 remote（改用此 deploy key）
sudo -u $ssh_user git -C <專案路徑> remote set-url origin gh-$alias:$owner_repo.git
EOF
}

# ============================================================
# add
# ============================================================

do_add() {
    local url="$1" alias="$2" ssh_user="$3"
    local owner_repo
    owner_repo=$(parse_owner_repo "$url") || error "無法解析 GitHub 網址/owner-repo 格式：$url"
    validate_alias "$alias" || error "alias 格式無效（僅允許英數字、- 、_）：$alias"
    id -u "$ssh_user" >/dev/null 2>&1 || error "系統帳號 '$ssh_user' 不存在，請先 useradd 建立"

    if repo_key_exists "$alias"; then
        error "alias「$alias」已存在於 repo-keys.conf；如需換鑰請用 rotate <alias>，或改用其他 alias 新增"
    fi

    local home_dir="/home/$ssh_user"
    local keys_dir="$home_dir/.ssh/keys"
    local key_path="$keys_dir/${alias}_ed25519"
    local config_file="$home_dir/.ssh/config"

    if [ -e "$key_path" ] || [ -e "${key_path}.pub" ]; then
        error "金鑰檔案已存在但未登記：$key_path（請手動確認後刪除，或改用其他 alias）"
    fi

    install -d -o "$ssh_user" -g "$ssh_user" -m 700 "$home_dir/.ssh"
    install -d -o "$ssh_user" -g "$ssh_user" -m 700 "$keys_dir"

    sudo -u "$ssh_user" ssh-keygen -t ed25519 -N "" \
        -C "deploy-key-${alias}@$(hostname)" -f "$key_path" >/dev/null

    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    chown "$ssh_user:$ssh_user" "$key_path" "${key_path}.pub"

    [ -f "$config_file" ] || touch "$config_file"
    write_ssh_config_block "$config_file" "$alias" "gh-$alias" "$owner_repo" "$key_path"
    chown "$ssh_user:$ssh_user" "$config_file"
    chmod 600 "$config_file"

    repo_key_add "$alias" "$owner_repo" "$ssh_user" "$key_path" "$(date +%F)"

    G_OWNER_REPO="$owner_repo"
    G_KEY_PATH="$key_path"
    G_SSH_USER="$ssh_user"
    G_PUBKEY="$(cat "${key_path}.pub")"
}

cmd_add() {
    local url="${1:?用法: repo-key add <github-url|owner/repo> [alias] [ssh_user]}"
    local alias="${2:-}"
    local ssh_user="${3:-${WEBOPS_USERNAME:-svc-app}}"
    local owner_repo
    owner_repo=$(parse_owner_repo "$url") || error "無法解析 GitHub 網址/owner-repo 格式：$url"
    [ -z "$alias" ] && alias="${owner_repo##*/}"

    do_add "$url" "$alias" "$ssh_user"

    echo
    info "✅ 已建立 deploy key：$alias → $G_OWNER_REPO（帳號 $G_SSH_USER）"
    echo
    echo "── Public Key（請貼到 GitHub） ──────────────────────────"
    echo "$G_PUBKEY"
    echo "──────────────────────────────────────────────────────────"
    echo "貼上網址：https://github.com/$G_OWNER_REPO/settings/keys/new"
    echo "（勾選 read-only，儲存）"
    print_git_commands "$alias" "$G_OWNER_REPO" "$G_SSH_USER"
    echo
    info "稍後可執行「repo-key test $alias」驗證連線"
}

tui_action_add() {
    local url alias ssh_user owner_repo
    url=$(tui_input "GitHub 網址或 owner/repo（例如 https://github.com/example-org/myapp）") || return
    [ -z "$url" ] && return
    owner_repo=$(parse_owner_repo "$url") || { tui_msg "❌ 無法解析：$url"; return; }
    alias=$(tui_input "Alias（好記名稱，用於 Host gh-<alias>）" "${owner_repo##*/}") || return
    [ -z "$alias" ] && return
    ssh_user=$(tui_input "SSH 目標帳號" "${WEBOPS_USERNAME:-svc-app}") || return
    [ -z "$ssh_user" ] && return

    do_add "$url" "$alias" "$ssh_user"

    local body
    body=$(printf '公開金鑰（請貼到 GitHub）：\n\n%s\n\n貼上網址：\nhttps://github.com/%s/settings/keys/new\n（勾選 read-only）\n%s' \
        "$G_PUBKEY" "$G_OWNER_REPO" "$(print_git_commands "$alias" "$G_OWNER_REPO" "$G_SSH_USER")")
    tui_scroll "新增 deploy key：$alias" "$body"

    if tui_yesno "已將上面的 public key 貼到 GitHub 了嗎？\n\n現在測試連線？"; then
        local out rc=0
        out=$(do_test "$alias" 2>&1) || rc=$?
        if [ "$rc" = 0 ]; then
            tui_msg "✅ 連線驗證成功\n\n$out"
        else
            tui_msg "❌ 連線驗證失敗\n\n$out"
        fi
    fi
}

# ============================================================
# test（GitHub -T 恆回 exit 1；判斷依據是輸出字串，不看 exit code）
# ============================================================

do_test() {
    local alias="$1"
    local row
    row=$(repo_key_get_row "$alias") || error "alias「$alias」未登記於 repo-keys.conf"
    local ssh_user
    IFS=$'\t' read -r _ _ ssh_user _ _ <<< "$row"
    local out
    out=$(sudo -u "$ssh_user" ssh -T "git@gh-$alias" -o StrictHostKeyChecking=accept-new 2>&1) || true
    echo "$out"
    echo "$out" | grep -q 'successfully authenticated'
}

cmd_test() {
    local alias="${1:?用法: repo-key test <alias>}"
    if do_test "$alias"; then
        info "✅ $alias 連線驗證成功（輸出含 successfully authenticated）"
    else
        warn "❌ $alias 連線驗證失敗"
        exit 1
    fi
}

# ============================================================
# list（本機登記，非 GitHub 即時狀態）
# ============================================================

cmd_list() {
    local f
    f="$(repo_key_conf_path)"
    if [ ! -f "$f" ]; then
        warn "尚未建立 webops/repo-keys.conf（尚無任何 deploy key 登記）"
        return 0
    fi
    echo "（以下為本機登記，非 GitHub 即時狀態）"
    printf "%-14s %-30s %-12s %s\n" "ALIAS" "OWNER/REPO" "SSH_USER" "CREATED"
    echo "---------------------------------------------------------------------------"
    local alias owner_repo ssh_user key_path created
    while IFS=$'\t' read -r alias owner_repo ssh_user key_path created; do
        [ -z "$alias" ] && continue
        printf "%-14s %-30s %-12s %s\n" "$alias" "$owner_repo" "$ssh_user" "$created"
        print_git_commands "$alias" "$owner_repo" "$ssh_user"
    done < <(repo_key_list_rows)
}

# ============================================================
# revoke（手動模式：本機端清除 + 提醒到 GitHub 手動移除）
# ============================================================

do_revoke() {
    local alias="$1"
    local row
    row=$(repo_key_get_row "$alias") || error "alias「$alias」未登記於 repo-keys.conf"
    local owner_repo ssh_user key_path
    IFS=$'\t' read -r _ owner_repo ssh_user key_path _ <<< "$row"
    local home_dir="/home/$ssh_user"
    local config_file="$home_dir/.ssh/config"

    rm -f "$key_path" "${key_path}.pub"
    remove_ssh_config_block "$config_file" "$alias"
    repo_key_remove "$alias"

    G_OWNER_REPO="$owner_repo"
    G_SSH_USER="$ssh_user"
}

cmd_revoke() {
    local alias="${1:?用法: repo-key revoke <alias>}"
    repo_key_exists "$alias" || error "alias「$alias」未登記於 repo-keys.conf"

    warn "即將撤銷 deploy key「$alias」（刪除本機私/公鑰、SSH config 區塊、登記行）"
    local confirm
    read -r -p "請輸入完整 alias 以確認（$alias）： " confirm
    [ "$confirm" = "$alias" ] || error "輸入不符，已取消"

    do_revoke "$alias"

    info "✅ 已撤銷本機端 $alias"
    warn "⚠️  請手動到 https://github.com/$G_OWNER_REPO/settings/keys 移除該 deploy key（手動模式無法代刪 GitHub 端）"
}

tui_action_revoke() {
    local alias confirm
    alias=$(tui_input "要撤銷的 alias") || return
    [ -z "$alias" ] && return
    repo_key_exists "$alias" || { tui_msg "❌ alias「$alias」未登記"; return; }

    confirm=$(tui_input "請再輸入一次完整 alias 以確認撤銷（$alias）") || return
    [ "$confirm" = "$alias" ] || { tui_msg "輸入不符，已取消"; return; }

    do_revoke "$alias"
    tui_msg "✅ 已撤銷本機端 $alias\n\n⚠️ 請手動到\nhttps://github.com/$G_OWNER_REPO/settings/keys\n移除該 deploy key"
}

# ============================================================
# rotate（不開天窗：新鑰測試通過才換掉舊鑰）
# ============================================================

do_rotate_prepare() {
    local alias="$1"
    local row
    row=$(repo_key_get_row "$alias") || error "alias「$alias」未登記於 repo-keys.conf"
    local owner_repo ssh_user key_path
    IFS=$'\t' read -r _ owner_repo ssh_user key_path _ <<< "$row"
    local home_dir="/home/$ssh_user"
    local config_file="$home_dir/.ssh/config"
    local new_key="${key_path}.new"

    rm -f "$new_key" "${new_key}.pub"
    sudo -u "$ssh_user" ssh-keygen -t ed25519 -N "" \
        -C "deploy-key-${alias}@$(hostname)" -f "$new_key" >/dev/null
    chmod 600 "$new_key"
    chmod 644 "${new_key}.pub"
    chown "$ssh_user:$ssh_user" "$new_key" "${new_key}.pub"

    write_ssh_config_block "$config_file" "${alias}-rotate" "gh-${alias}-rotate" "$owner_repo" "$new_key"
    chown "$ssh_user:$ssh_user" "$config_file"
    chmod 600 "$config_file"

    G_OWNER_REPO="$owner_repo"
    G_SSH_USER="$ssh_user"
    G_KEY_PATH="$key_path"
    G_NEW_KEY="$new_key"
    G_PUBKEY="$(cat "${new_key}.pub")"
}

do_rotate_test() {
    local alias="$1" ssh_user="$2"
    local out
    out=$(sudo -u "$ssh_user" ssh -T "git@gh-${alias}-rotate" -o StrictHostKeyChecking=accept-new 2>&1) || true
    echo "$out"
    echo "$out" | grep -q 'successfully authenticated'
}

do_rotate_finalize() {
    local alias="$1" ssh_user="$2" key_path="$3" new_key="$4"
    local home_dir="/home/$ssh_user"
    local config_file="$home_dir/.ssh/config"

    mv -f "$new_key" "$key_path"
    mv -f "${new_key}.pub" "${key_path}.pub"
    remove_ssh_config_block "$config_file" "${alias}-rotate"

    local f tmp today
    f="$(repo_key_conf_path)"
    tmp=$(mktemp)
    today="$(date +%F)"
    awk -F'\t' -v a="$alias" -v d="$today" 'BEGIN{OFS="\t"} !/^#/ && $1==a {$5=d} {print}' "$f" > "$tmp"
    mv "$tmp" "$f"
    chmod 600 "$f"
}

do_rotate_abort() {
    local alias="$1" ssh_user="$2" new_key="$3"
    local home_dir="/home/$ssh_user"
    local config_file="$home_dir/.ssh/config"
    rm -f "$new_key" "${new_key}.pub"
    remove_ssh_config_block "$config_file" "${alias}-rotate"
}

cmd_rotate() {
    local alias="${1:?用法: repo-key rotate <alias>}"
    repo_key_exists "$alias" || error "alias「$alias」未登記於 repo-keys.conf"

    do_rotate_prepare "$alias"

    echo
    info "🔄 已產生新金鑰（尚未生效）：$alias → $G_OWNER_REPO"
    echo
    echo "── 新 Public Key（請到 GitHub 新增，暫時保留舊 key） ──────"
    echo "$G_PUBKEY"
    echo "────────────────────────────────────────────────────────"
    echo "貼上網址：https://github.com/$G_OWNER_REPO/settings/keys/new"
    echo

    local ans
    read -r -p "已將新 public key 貼到 GitHub 了嗎？測試通過才會換鑰。輸入 yes 繼續，其他取消： " ans
    if [ "$ans" != "yes" ]; then
        do_rotate_abort "$alias" "$G_SSH_USER" "$G_NEW_KEY"
        warn "已取消 rotate，舊鑰保持不變（不開天窗）"
        exit 1
    fi

    local out rc=0
    out=$(do_rotate_test "$alias" "$G_SSH_USER") || rc=$?
    echo "$out"
    if [ "$rc" != 0 ]; then
        do_rotate_abort "$alias" "$G_SSH_USER" "$G_NEW_KEY"
        error "新金鑰測試失敗（未含 successfully authenticated），已中止並保留舊鑰"
    fi

    do_rotate_finalize "$alias" "$G_SSH_USER" "$G_KEY_PATH" "$G_NEW_KEY"
    info "✅ $alias 已完成輪替，新鑰已生效（Host gh-$alias 路徑不變）"
    warn "⚠️  請手動到 https://github.com/$G_OWNER_REPO/settings/keys 移除舊的 deploy key"
    print_git_commands "$alias" "$G_OWNER_REPO" "$G_SSH_USER"
}

tui_action_rotate() {
    local alias
    alias=$(tui_input "要輪替的 alias") || return
    [ -z "$alias" ] && return
    repo_key_exists "$alias" || { tui_msg "❌ alias「$alias」未登記"; return; }

    do_rotate_prepare "$alias"

    local body
    body=$(printf '新 Public Key（請到 GitHub 新增，暫時保留舊 key）：\n\n%s\n\n貼上網址：\nhttps://github.com/%s/settings/keys/new' \
        "$G_PUBKEY" "$G_OWNER_REPO")
    tui_scroll "輪替 $alias — 步驟 1/2：新增新鑰" "$body"

    if ! tui_yesno "已將新 public key 貼到 GitHub 了嗎？\n\n現在測試新鑰？（測試失敗會保留舊鑰，不開天窗）"; then
        do_rotate_abort "$alias" "$G_SSH_USER" "$G_NEW_KEY"
        tui_msg "已取消 rotate，舊鑰保持不變"
        return
    fi

    local out rc=0
    out=$(do_rotate_test "$alias" "$G_SSH_USER") || rc=$?
    if [ "$rc" != 0 ]; then
        do_rotate_abort "$alias" "$G_SSH_USER" "$G_NEW_KEY"
        tui_msg "❌ 新金鑰測試失敗，已中止並保留舊鑰\n\n$out"
        return
    fi

    do_rotate_finalize "$alias" "$G_SSH_USER" "$G_KEY_PATH" "$G_NEW_KEY"
    local msg
    msg=$(printf '✅ %s 已完成輪替\n\n⚠️ 請手動到 GitHub 移除舊的 deploy key\n%s' \
        "$alias" "$(print_git_commands "$alias" "$G_OWNER_REPO" "$G_SSH_USER")")
    tui_msg "$msg"
}

# ============================================================
# 分派：帶子命令 → CLI；無參數 + whiptail 可用 → TUI
# ============================================================

if [ -n "${1:-}" ]; then
    case "$1" in
        add)    shift; cmd_add    "$@" ;;
        list)   cmd_list ;;
        test)   shift; cmd_test   "$@" ;;
        revoke) shift; cmd_revoke "$@" ;;
        rotate) shift; cmd_rotate "$@" ;;
        -h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
    exit 0
fi

tui_available || { usage; error "無參數且未安裝 whiptail；請 apt install -y whiptail 或改用子命令"; }

while true; do
    CHOICE=$(tui_menu "GitHub Deploy Key 管理" \
        "add"    "新增 deploy key" \
        "list"   "列出登記表" \
        "test"   "測試連線" \
        "revoke" "撤銷" \
        "rotate" "輪替" \
        "back"   "返回上一層") || exit 0

    case "$CHOICE" in
        add)
            tui_action_add
            ;;
        list)
            CONTENT=$(cmd_list 2>&1)
            tui_scroll "repo-keys.conf" "$CONTENT"
            ;;
        test)
            ALIAS=$(tui_input "要測試的 alias") || continue
            [ -z "$ALIAS" ] && continue
            OUT=$(do_test "$ALIAS" 2>&1) && tui_msg "✅ 連線成功\n\n$OUT" || tui_msg "❌ 連線失敗\n\n$OUT"
            ;;
        revoke)
            tui_action_revoke
            ;;
        rotate)
            tui_action_rotate
            ;;
        back)
            exit 0
            ;;
    esac
done
