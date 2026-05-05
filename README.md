# automation-sh

Shell scripts for issuing and installing wildcard SSL certificates using [acme.sh](https://github.com/acmesh-official/acme.sh) with Cloudflare DNS validation.

## Prerequisites

- Debian/Ubuntu Linux server
- Root or sudo access
- nginx installed
- A Cloudflare account managing your domain's DNS
- A Cloudflare API token with **Zone: DNS: Edit** permission (scoped to your zone)
  - Optionally also **Zone: Zone: Read** if you want webops to auto-discover `zone_id` (see [webops](#webops--多主網域部署框架tui) section)

## Setup

1. Clone this repository onto your server.
2. Copy the example env file and fill in your credentials:

```bash
cp .env.example .env
nano .env
```

`.env` variables:

| Variable    | Required | Description                                      |
|-------------|----------|--------------------------------------------------|
| `ACME_EMAIL`| Yes      | Email for Let's Encrypt account registration     |
| `CF_Token`  | Yes      | Cloudflare API token (DNS Edit permission)       |
| `SSL_DIR`   | No       | Certificate install path (default: `/etc/nginx/ssl`) |
| `DB_USER`   | for backup | MariaDB user used by `backup_databases.sh`     |
| `DB_PASS`   | for backup | MariaDB password (avoid spaces / `# " ' $`)    |
| `DB_HOST`   | No       | MariaDB host (default: `localhost`)              |
| `BACKUP_DIR` | for backup | Where `.sql.gz` dumps are written              |
| `BACKUP_LOG_DIR` | for backup | Log directory                              |
| `BACKUP_MOUNT_POINT` | for backup | Required mount point (script aborts if not mounted) |
| `BACKUP_DBS` | for backup | Backup targets, space-separated. Each item is `db` or `db:table1,table2` |
| `BACKUP_RETENTION_DAYS` | No | Days to keep old dumps (default: `30`)      |

> **Warning:** Never commit `.env` to version control. It is already gitignored.

## Usage

### Step 1 — Install acme.sh

Run once per server:

```bash
chmod +x install_acme.sh
sudo ./install_acme.sh
```

This installs acme.sh to `/root/.acme.sh`, sets Let's Encrypt as the default CA, stores your Cloudflare token, and configures automatic renewal via cron.

### Step 2 — Issue and install a wildcard certificate

```bash
sudo ./install_wildcard_ssl.sh yourdomain.com
```

This issues a certificate for `yourdomain.com` and `*.yourdomain.com` via Cloudflare DNS challenge, then installs it to `$SSL_DIR` and reloads nginx.

**Output files:**

| File | Description |
|------|-------------|
| `$SSL_DIR/yourdomain.com.crt` | Full-chain certificate |
| `$SSL_DIR/yourdomain.com.key` | Private key |

### Step 3 — Configure nginx

Reference the installed certificate in your nginx server block:

```nginx
ssl_certificate     /etc/nginx/ssl/yourdomain.com.crt;
ssl_certificate_key /etc/nginx/ssl/yourdomain.com.key;
```

### backup_databases.sh — Scheduled MariaDB backups

```bash
chmod +x backup_databases.sh
sudo ./backup_databases.sh
```

Backs up the targets listed in `BACKUP_DBS` using `mariadb-dump --single-transaction` (no table locks), gzips them to `BACKUP_DIR`, writes a log to `BACKUP_LOG_DIR`, and prunes dumps older than `BACKUP_RETENTION_DAYS`.

#### `BACKUP_DBS` syntax

Each space-separated entry can be a whole database **or** a subset of tables:

| Entry                          | Effect                                            | Output filename                              |
|--------------------------------|---------------------------------------------------|----------------------------------------------|
| `voxy`                         | Dump the whole `voxy` database                    | `voxy_YYYYMMDD_HHMM.sql.gz`                  |
| `voxy:users`                   | Dump only the `users` table from `voxy`           | `voxy_users_YYYYMMDD_HHMM.sql.gz`            |
| `voxy:users,lessons,orders`    | Dump these three tables from `voxy` (one file)    | `voxy_users-lessons-orders_YYYYMMDD_HHMM.sql.gz` |

You can mix entries and even repeat the same DB to split tables into separate files:

```bash
# Whole DB + selected tables from another DB
BACKUP_DBS="voxy global_voxy:users,sessions"

# Same DB, two separate dump files (e.g. hot tables vs reference tables)
BACKUP_DBS="voxy:orders,payments voxy:countries,currencies"
```

Notes:
- Table names use commas (no spaces). Spaces only separate top-level entries.
- A failed dump (missing table, wrong credentials, etc.) is moved to `*.sql.gz.bad` and the loop continues with the next entry.
- Per-table dumps still use `--single-transaction`, so InnoDB tables are consistent within each entry but not across entries.

#### Safety features

- Aborts if `BACKUP_MOUNT_POINT` is not mounted (protects the system disk).
- Lock file at `/tmp/backup_databases.lock` prevents concurrent runs.
- Credentials passed to `mariadb-dump` via a `chmod 600` temp file (not visible in `ps`).
- Runs at lowest CPU/IO priority (`nice -n19`, `ionice -c3`).

Recommended cron entry (daily at 03:30):

```cron
30 3 * * * /path/to/backup_databases.sh >/dev/null 2>&1
```

### webops — 多主網域部署框架（TUI）

`webops/` 是給開發者直接使用的部署工具集（非維運取向）：以 whiptail TUI 操作 Cloudflare DNS、Nginx vhost、Laravel queue/scheduler、站點生命週期。安裝後可在 server 上以 `sudo webops` 進入主選單，或直接用各別 CLI 子命令。

#### 安裝

```bash
chmod +x install_webops.sh
sudo ./install_webops.sh
```

安裝動作：

1. `apt-get install -y whiptail jq curl`
2. 設定 `webops/*.sh` 執行權限
3. 在 `/usr/local/bin/` 建立 7 個 symlink（`webops`, `domain-mgr`, `cf-dns`, `deploy-site`, `site-mgr`, `laravel-svc`, `nginx-ctl`）
4. 若 `webops/domains.conf` 不存在，引導加入第一個主網域

#### 主網域註冊表 `webops/domains.conf`

格式（TAB 分隔，gitignore）。`zone_id` 欄位**選填**：

```
# domain          zone_id                 note
example.com                               主站（zone_id 留空 → auto-discover）
client-a.example  <cloudflare_zone_id>    客戶 A（顯式 zone_id）
```

| zone_id 欄位 | 行為 | Token 需求 |
|------|------|-----------|
| 留空 | webops 呼叫 `GET /zones?name=<domain>` 自動取得，快取到 `webops/.zone-cache`（gitignore） | `Zone:DNS:Edit` + **`Zone:Zone:Read`** |
| 填入 | 直接使用顯式值，零 API 探查 | `Zone:DNS:Edit` |

兩種混用 OK：可一筆填一筆空，看你 token 權限。範本 `webops/domains.conf.example` 提供兩種 placeholder。維護方式：執行 `sudo domain-mgr` → 選「註冊新主網域」（zone_id 欄位可直接 Enter 跳過）。

#### `.env` 變數

| 變數 | 預設 | 說明 |
|------|------|------|
| `CF_Token` | （重用上方）| 需對 `domains.conf` 內所有 zone 有 `Zone:DNS:Edit`；zone_id 留空時還需 `Zone:Zone:Read` |
| `WEBOPS_BASE_DIR` | `/home/svc-app/public_html` | 站點根目錄 |
| `WEBOPS_USERNAME` | `svc-app` | 站點檔案 owner |
| `WEBOPS_SSL_PATH` | `$SSL_DIR` (`/etc/nginx/ssl`) | SSL 憑證路徑 |
| `WEBOPS_PHP_FPM_SOCK` | 自動偵測 | PHP-FPM socket |

#### 使用

主入口：

```bash
sudo webops          # whiptail 主選單（6 大功能）
```

子命令直呼：

```bash
# 網域 / DNS
sudo domain-mgr                              # TUI 網域管理
sudo cf-dns add <prefix> <main-domain>       # 快速新增子網域
sudo cf-dns rm  <fqdn>                       # 刪除子網域
sudo cf-dns ls  <main-domain>                # 列出 zone DNS 記錄
sudo cf-dns check <fqdn>                     # 查詢記錄

# 站點部署 / 管理
sudo deploy-site                                  # TUI 互動部署
sudo deploy-site sub.example.com hybrid 3000      # 直接呼叫（部署到預設 svc-app）
sudo deploy-site sub.example.com hybrid 3000 foo  # 部署到 /home/foo/public_html/
sudo site-mgr                                     # 站點清單與刪除

# 服務 / Nginx
sudo laravel-svc                             # Laravel queue/sched 管理
sudo nginx-ctl reload | restart | test       # Nginx 控制
```

支援的部署模式：`php`、`laravel`、`hybrid`（前端 proxy + `/api` Laravel）、`python`（proxy 到後端 port）。

#### 多帳號部署（per-deploy 帳號 / base dir 覆寫）

預設部署到 `WEBOPS_USERNAME` 的 `WEBOPS_BASE_DIR`。每次部署可指定其他帳號：

- **TUI**：`sudo deploy-site` 進入後會詢問「用預設帳號嗎？」選否可指定其他系統帳號與 base dir。
- **CLI**：第 4 個位置參數帶帳號名稱，例如 `sudo deploy-site lab.example.com hybrid 3000 foo` 會部署到 `/home/foo/public_html/lab.example.com/` 並 `chown foo:www-data`。

**前提**：目標帳號必須由管理員預先建立並設定權限，否則部署會中止：

```bash
sudo useradd -m -s /bin/bash foo
sudo usermod -aG www-data foo
# base dir 父目錄需存在，可由 deploy-site 自動建立 base dir 本身
```

`laravel-svc` 會自動偵測 `/home/*/public_html/<domain>` 找出 Laravel app 路徑，找不到時會詢問。

#### 向前相容

新版 `site-mgr` 與「網域總覽」同時識別兩種 nginx vhost 標籤：

- `# [webops-managed]` — 新版部署
- `# [EasyAI-Managed]` — 舊版部署（顯示為 `MANAGED*`，刪除流程相同）

既有站點目錄、supervisor confs 不需重建，新框架直接接管。

### install_phpmyadmin.sh — Install phpMyAdmin

```bash
chmod +x install_phpmyadmin.sh
sudo ./install_phpmyadmin.sh
```

This fetches the latest phpMyAdmin release from GitHub, installs it to `/var/www/html/phpmyadmin`, generates a random `blowfish_secret`, and sets correct ownership for `www-data`. No `.env` required.

**After installation**, configure an Nginx server block pointing to `/var/www/html/phpmyadmin` and restrict access by IP.

---

## Auto-renewal

acme.sh automatically installs a cron job that renews certificates before expiry and reloads nginx. No manual intervention needed.

## Security Notes

- Keep `CF_Token` scoped to **DNS Edit only** on the target zone — do not use a global API key.
- The `.env` file is gitignored. Never add real credentials to `.env.example` or any tracked file.
- Certificate files (`.pem`, `.key`) are also gitignored.
