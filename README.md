# automation-sh

Shell scripts for issuing and installing wildcard SSL certificates using [acme.sh](https://github.com/acmesh-official/acme.sh) with Cloudflare DNS validation.

## Prerequisites

- Debian/Ubuntu Linux server
- Root or sudo access
- nginx installed
- A Cloudflare account managing your domain's DNS
- A Cloudflare API token with **Zone: DNS: Edit** permission (scoped to your zone)

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
