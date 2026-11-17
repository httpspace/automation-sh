#!/bin/bash
# webops/lib/db.sh — deploy-site 第 9 步的建庫邏輯（MariaDB 預設，可選 PostgreSQL）
# 此檔案僅供 source，不直接執行。
# 依賴：呼叫端需已 source common.sh（warn）、tui.sh（tui_available / tui_msg）。
#
# 引擎由 .env 的 WEBOPS_DB_ENGINE 決定：
#   mariadb（預設；未設 / 空值 / 無效值皆為 mariadb）
#   postgresql（別名 pgsql、postgres）
# MODE=wordpress 一律用 mariadb（WordPress 不支援 PostgreSQL）。
#
# 對外函式：
#   db_engine_for <mode>             印出實際使用的引擎（mariadb | postgresql），無副作用
#   db_engine_notices <mode>         引擎相關的警告 / 通知（無效值、wordpress 例外），只在需要時輸出
#   db_summary_suffix <engine>       SUMMARY「建議 DB」後綴（mariadb 為空字串）
#   db_yesno_text <name> <engine>    第 9 步 yesno 的提示文字
#   db_create <name> <mode>          建庫 + 顯示結果（一律回傳 0）

# 以 postgres 系統帳號（peer）執行 PG 指令；先清掉呼叫端環境中的 libpq 變數
# （PGHOST/PGUSER 等若存在，runuser 會原樣帶過去，導致改走 TCP / 其他 role 而被 pg_hba 拒絕）
_db_pg_run() {
    env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGUSER -u PGDATABASE -u PGPASSWORD \
        -u PGPASSFILE -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGSSLMODE \
        runuser -u postgres -- "$@"
}

# 印出正規化後的引擎設定值；無法辨識時印 invalid
_db_normalize_engine() {
    local raw="${WEBOPS_DB_ENGINE:-}"
    raw="${raw,,}"
    case "$raw" in
        ""|mariadb) echo "mariadb" ;;
        postgresql|pgsql|postgres) echo "postgresql" ;;
        *) echo "invalid" ;;
    esac
}

db_engine_for() {
    local mode="${1:-}" eng
    eng=$(_db_normalize_engine)
    case "$eng" in
        postgresql)
            if [ "$mode" = "wordpress" ]; then
                echo "mariadb"
            else
                echo "postgresql"
            fi
            ;;
        *) echo "mariadb" ;;
    esac
}

db_engine_notices() {
    local mode="${1:-}" eng
    eng=$(_db_normalize_engine)
    if [ "$eng" = "invalid" ]; then
        warn "WEBOPS_DB_ENGINE=${WEBOPS_DB_ENGINE} 無法辨識（可用 mariadb / postgresql），改用 mariadb"
    elif [ "$eng" = "postgresql" ] && [ "$mode" = "wordpress" ]; then
        if tui_available; then
            tui_msg "ℹ️ WordPress 不支援 PostgreSQL，已改用 MariaDB"
        else
            warn "WordPress 不支援 PostgreSQL，已改用 MariaDB"
        fi
    fi
    return 0
}

db_summary_suffix() {
    if [ "${1:-mariadb}" = "postgresql" ]; then
        printf '%s' " [PostgreSQL]"
    fi
    return 0
}

db_yesno_text() {
    local DB_NAME="$1" engine="${2:-mariadb}"
    if [ "$engine" = "postgresql" ]; then
        printf '%s' "順便建立 PostgreSQL 資料庫 $DB_NAME？\n\n會用 postgres 系統帳號（peer 認證）執行：\n\n  createdb -E UTF8 -T template0 $DB_NAME\n\n（先查 pg_database — 已存在就跳過，不會清資料；名稱會轉小寫，上限 63 bytes）"
    else
        printf '%s' "順便建立 MariaDB 資料庫 $DB_NAME？\n\n會用 root socket 認證執行：\n\n  CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`\n    CHARACTER SET utf8mb4\n    COLLATE utf8mb4_unicode_ci;\n\n（IF NOT EXISTS — 已存在就跳過，不會清資料）"
    fi
}

# MariaDB 建庫（自 deploy-site.sh 第 9 步逐字搬入，僅調整縮排與包成函式）
_db_create_mariadb() {
    local DB_NAME="$1" DB_CLI DB_LOG
        DB_CLI=""
        if command -v mariadb >/dev/null 2>&1; then
            DB_CLI="mariadb"
        elif command -v mysql >/dev/null 2>&1; then
            DB_CLI="mysql"
        fi

        if [ -z "$DB_CLI" ]; then
            tui_msg "❌ 找不到 mariadb / mysql CLI\n\n請先安裝：\n  sudo apt install -y mariadb-client\n（或 mariadb-server）"
        else
            DB_LOG=$(mktemp)
            if "$DB_CLI" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>"$DB_LOG"; then
                tui_msg "✅ 資料庫 $DB_NAME 已就緒\n\n字符集:  utf8mb4 / utf8mb4_unicode_ci\nCLI:     $DB_CLI\n\n下一步（建議）建立應用 user 並 GRANT 權限：\n\n  $DB_CLI -e \"\\\nCREATE USER '${DB_NAME}'@'localhost' IDENTIFIED BY '<password>';\\\nGRANT ALL ON \\\`$DB_NAME\\\`.* TO '${DB_NAME}'@'localhost';\\\nFLUSH PRIVILEGES;\""
            else
                tui_msg "❌ 建立 $DB_NAME 失敗\n\n$(cat "$DB_LOG")\n\n常見原因：\n  • MariaDB/MySQL server 沒在跑（systemctl status mariadb）\n  • root 不是 socket 認證（需 ~/.my.cnf 帶密碼）"
            fi
            rm -f "$DB_LOG"
        fi
}

# PostgreSQL 建庫（peer 認證；已存在就跳過，絕不刪任何東西）
_db_create_postgresql() {
    local name="${1,,}" mode="${2:-}" len db_log exists owner="${WEBOPS_PG_DB_OWNER:-}" role_ok

    len=$(printf '%s' "$name" | LC_ALL=C wc -c | tr -d '[:space:]')
    if [ "$len" -gt 63 ]; then
        tui_msg "❌ 資料庫名稱過長：$name\n\nPostgreSQL 識別字上限 63 bytes（目前 $len），超過會被默默截斷，\n可能與其他庫撞名，因此拒絕建立。\n\n請改用較短的網域，或手動 createdb 自訂名稱。"
        return 0
    fi

    if ! command -v psql >/dev/null 2>&1 || ! command -v createdb >/dev/null 2>&1 \
        || ! command -v runuser >/dev/null 2>&1 || ! id -u postgres >/dev/null 2>&1; then
        tui_msg "❌ 找不到 psql CLI 或 postgres 系統帳號\n\n請先安裝：\n  sudo apt install -y postgresql\n（或僅 postgresql-client；但本機建庫需要 postgresql server）"
        return 0
    fi

    if [ -n "$owner" ]; then
        if [ "${#owner}" -gt 63 ] || ! [[ "$owner" =~ ^[a-z_][a-z0-9_]*$ ]]; then
            tui_msg "❌ WEBOPS_PG_DB_OWNER 名稱不合法：$owner\n\n只允許小寫英文、數字、底線（不可數字開頭），長度上限 63。\n請修正 .env 後重試；未建立資料庫。"
            return 0
        fi
    fi

    db_log=$(mktemp)
    # 庫名只含 [a-z0-9_]（由網域轉出），可安全放進 SQL 字串
    if ! exists=$(_db_pg_run psql -X -tAc "SELECT 1 FROM pg_database WHERE datname='${name}'" 2>"$db_log"); then
        tui_msg "❌ 查詢 PostgreSQL 失敗\n\n$(cat "$db_log")\n\n常見原因：\n  • PostgreSQL server 沒在跑（systemctl status postgresql）"
        rm -f "$db_log"
        return 0
    fi
    exists="${exists//[[:space:]]/}"

    if [ "$exists" = "1" ]; then
        if [ -n "$owner" ]; then
            tui_msg "ℹ️ 資料庫 $name 已存在，跳過（不會清資料、不會變更擁有者）\n\n若既有庫的擁有者不是 ${owner}，可手動執行：\n\n  sudo -u postgres psql -c \"ALTER DATABASE ${name} OWNER TO ${owner};\""
        else
            tui_msg "ℹ️ 資料庫 $name 已存在，跳過（不會清資料）\n\n若尚未建立應用 role，見下一步：\n\n  sudo -u postgres psql -c \"CREATE ROLE ${name} LOGIN PASSWORD '<password>';\"\n  sudo -u postgres psql -c \"ALTER DATABASE ${name} OWNER TO ${name};\""
        fi
        rm -f "$db_log"
        return 0
    fi

    local -a owner_args=()
    if [ -n "$owner" ]; then
        if ! role_ok=$(_db_pg_run psql -X -tAc "SELECT 1 FROM pg_roles WHERE rolname='${owner}'" 2>"$db_log"); then
            tui_msg "❌ 查詢 PostgreSQL 失敗\n\n$(cat "$db_log")\n\n常見原因：\n  • PostgreSQL server 沒在跑（systemctl status postgresql）"
            rm -f "$db_log"
            return 0
        fi
        role_ok="${role_ok//[[:space:]]/}"
        if [ "$role_ok" != "1" ]; then
            tui_msg "❌ PostgreSQL role ${owner} 不存在，未建立資料庫\n\n請先建立 role：\n\n  sudo -u postgres psql -c \"CREATE ROLE ${owner} LOGIN PASSWORD '<password>';\"\n\n（或清空 .env 的 WEBOPS_PG_DB_OWNER 改由 postgres 擁有）"
            rm -f "$db_log"
            return 0
        fi
        owner_args=(-O "$owner")
    fi

    if _db_pg_run createdb -E UTF8 -T template0 ${owner_args[@]+"${owner_args[@]}"} "$name" 2>"$db_log"; then
        local next="✅ 資料庫 $name 已就緒\n\n編碼:    UTF8（template0）\nCLI:     psql（postgres 系統帳號 peer 認證）\n\n下一步（建議）建立應用 role 並設為 owner：\n\n  CREATE ROLE ${name} LOGIN PASSWORD '<password>';\n  ALTER DATABASE ${name} OWNER TO ${name};\n\n（PG15+ 的 public schema 預設不再開放給一般 role 建表，\n  所以需把 DB owner 交給應用 role）"
        if [ "$mode" = "laravel" ] || [ "$mode" = "hybrid" ]; then
            next="$next\n\nLaravel .env 設 DB_CONNECTION=pgsql。\n若 php -m 沒有 pdo_pgsql，需另外安裝 php8.x-pgsql（此工具不會代裝）。"
        fi
        if [ -n "$owner" ]; then
            next="✅ 資料庫 $name 已就緒\n\n編碼:    UTF8（template0）\n擁有者:  ${owner}\nCLI:     psql（postgres 系統帳號 peer 認證）"
            if [ "$mode" = "laravel" ] || [ "$mode" = "hybrid" ]; then
                next="$next\n\nLaravel .env 設 DB_CONNECTION=pgsql、DB_USERNAME=${owner}。\n若 php -m 沒有 pdo_pgsql，需另外安裝 php8.x-pgsql（此工具不會代裝）。"
            fi
        fi
        tui_msg "$next"
    else
        tui_msg "❌ 建立 $name 失敗\n\n$(cat "$db_log")\n\n常見原因：\n  • PostgreSQL server 沒在跑（systemctl status postgresql）\n  • postgres 帳號無法執行 createdb"
    fi
    rm -f "$db_log"
    return 0
}

db_create() {
    local name="$1" mode="${2:-}" engine
    engine=$(db_engine_for "$mode")
    if [ "$engine" = "postgresql" ]; then
        _db_create_postgresql "$name" "$mode"
    else
        _db_create_mariadb "$name"
    fi
    return 0
}
