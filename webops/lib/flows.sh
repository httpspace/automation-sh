#!/bin/bash
# webops/lib/flows.sh — 跨入口共用的互動流程（webops.sh 主選單 / advanced.sh 進階模式共用）
# 此檔案僅供 source，不直接執行。
# 需先 source: common.sh（webops_dir）、tui.sh、domains.sh；呼叫端需已設 WEBOPS_DIR。

# 加子網域（並可立刻部署）— 主選單 add-sub 與進階模式 Cloudflare/網域 › 加子網域 共用同一份。
# 原本是 webops.sh 主迴圈 case 內的程式；`continue` 改為 `return 0`（等價：回到呼叫端選單）。
flow_add_sub() {
    local MAIN SUB output rc NEW_FQDN
    domains_require_conf
    MAIN=$(tui_pick_domain) || return 0
    SUB=$(tui_input "子網域前綴（例如 lab；留空或 @ = 主網域 $MAIN apex 本身）" "") || return 0
    # 不阻擋空 SUB — cf-dns.sh add 處理「空 / @」一律當 apex
    output=$("$WEBOPS_DIR/cf-dns.sh" add "$SUB" "$MAIN" 2>&1) && rc=0 || rc=$?
    if [ "$rc" = 0 ]; then
        tui_msg "✅ DNS 記錄已建立\n\n$output"
        # 推導 FQDN 並提供「立刻部署」捷徑
        if [ -z "$SUB" ] || [ "$SUB" = "@" ]; then
            NEW_FQDN="$MAIN"
        else
            NEW_FQDN="$SUB.$MAIN"
        fi
        if tui_yesno "立刻部署 $NEW_FQDN 嗎？\n\n（直接帶網域進部署流程，省掉再選一次）"; then
            "$WEBOPS_DIR/deploy-site.sh" "$NEW_FQDN" || true
        fi
    else
        tui_msg "❌ 失敗 (exit $rc)\n\n$output"
    fi
    return 0
}
