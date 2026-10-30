#!/bin/bash
# webops/lib/ssl.sh — 在 TUI 內簽發 / 更新主網域 wildcard SSL 憑證
# 此檔案僅供 source，不直接執行。
# 依賴：呼叫端需已 source common.sh、tui.sh、domains.sh，並已 load_env（用到 CF_Token）。
#       cf.sh（CF_API）若尚未載入，這裡會自動補 source。
#
# 簽發本身交給 repo 根目錄的 install_wildcard_ssl.sh（DNS challenge，約 1 到 3 分鐘）；
# 本檔只負責前置檢查、互動詢問與呼叫。token 尚未授權該 zone 時只提醒，不動手簽。

if [ -z "${CF_API:-}" ]; then
    # shellcheck source=cf.sh
    source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cf.sh"
fi

# 用法: ssl_issue_flow <main-domain>
# 回傳 0 = 簽發成功，或使用者取消前已有有效憑證可用；非 0 = 失敗或取消。
# 所有 curl / jq 都用 if 或 || 包住，避免呼叫端 set -e 直接退出。
ssl_issue_flow() {
    local main="${1:-}"
    local repo acme_bin resp zid status_resp enddate answer
    local key_choice="" ssl_args=() crt

    if [ -z "$main" ]; then
        tui_msg "❌ 未指定主網域。"
        return 1
    fi

    [ -n "${WEBOPS_SSL_PATH:-}" ] || apply_webops_defaults
    repo="$(dirname "$(webops_dir)")"
    acme_bin="/root/.acme.sh/acme.sh"

    # === 1. 前置檢查（任一不過就說明後中止，不動手簽）===
    if [ ! -f "$acme_bin" ]; then
        tui_msg "❌ 找不到 acme.sh（$acme_bin）\n\n請先在 CLI 執行：\n  sudo ./install_acme.sh"
        return 1
    fi

    if [ -z "${CF_Token:-}" ]; then
        tui_msg "❌ .env 缺少 CF_Token，無法使用 Cloudflare DNS 驗證。\n\n請在 .env 補上 CF_Token（權限 Zone:DNS:Edit，建議再加 Zone:Zone:Read）。"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        tui_msg "❌ 需要 curl 與 jq（apt install -y curl jq）"
        return 1
    fi

    # token 本身是否有效且啟用
    status_resp=""
    if ! status_resp=$(curl -fsSL --max-time 15 "$CF_API/user/tokens/verify" \
            -H "Authorization: Bearer $CF_Token" 2>/dev/null); then
        status_resp=""
    fi
    if [ "$(echo "$status_resp" | jq -r '.success' 2>/dev/null || true)" != "true" ] \
        || [ "$(echo "$status_resp" | jq -r '.result.status' 2>/dev/null || true)" != "active" ]; then
        tui_msg "❌ CF_Token 無效或未啟用。\n\n請到 Cloudflare 確認 token 狀態，並更新 .env 的 CF_Token。"
        return 1
    fi

    # zone_id（domains.conf 顯式值 → cache → CF API 探查）
    if ! zid=$(domains_resolve_zone_id "$main" 2>/dev/null) || [ -z "$zid" ]; then
        tui_msg "❌ 找不到 $main 的 zone_id\n\n主網域未註冊，或 token 缺 Zone:Zone:Read。"
        return 1
    fi

    # token 是否被授權到此 zone 的 DNS 權限。
    # 寫入權限無法「不寫就驗證」，所以退而求其次：能讀此 zone 的 DNS 記錄，
    # 加上上面 token 為 active，當作提醒門檻；真正的 Zone:DNS:Edit 缺失仍可能在簽發時才失敗。
    resp=""
    if ! resp=$(curl -fsSL --max-time 15 -G "$CF_API/zones/$zid/dns_records" \
            --data-urlencode "per_page=1" \
            -H "Authorization: Bearer $CF_Token" 2>/dev/null); then
        resp=""
    fi
    if [ "$(echo "$resp" | jq -r '.success' 2>/dev/null || true)" != "true" ]; then
        tui_msg "⚠️ token 尚未授權此 zone 的 DNS 權限（需 Zone:DNS:Edit）。\n\n請到 Cloudflare 補權限後再試。本次不會簽發。"
        return 1
    fi

    # === 2. 憑證狀態 ===
    crt="$WEBOPS_SSL_PATH/$main.crt"
    if [ -f "$crt" ]; then
        enddate="無法讀取"
        if command -v openssl >/dev/null 2>&1; then
            enddate=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | sed 's/^notAfter=//' || true)
            [ -n "$enddate" ] || enddate="無法讀取"
        fi
        tui_yesno "憑證已存在，到期 $enddate，要 --force 重簽嗎？" || return 0
        ssl_args+=("--force")
    else
        tui_yesno "要為 $main 與 *.$main 簽發嗎？（DNS challenge 約 1 到 3 分鐘）" || return 1
    fi

    # === 3. 金鑰類型 ===
    key_choice=$(tui_menu "選擇金鑰類型" \
        "ecc" "ECC（預設，建議）" \
        "rsa" "RSA 2048（Azure CDN 等舊平台）") || return 1
    if [ "$key_choice" = "rsa" ]; then
        ssl_args=("--rsa" "${ssl_args[@]}")
    fi

    # === 4. 簽發 ===
    tui_run_with_log "簽發 SSL：$main" "$repo/install_wildcard_ssl.sh" "$main" "${ssl_args[@]}"
}
