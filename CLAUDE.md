# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a shell script automation repository for SSL certificate management on Linux servers using [acme.sh](https://github.com/acmesh-official/acme.sh) with Cloudflare DNS validation.

## Scripts

### `install_acme.sh`
Installs acme.sh and configures Cloudflare DNS credentials. Must be run first.

```bash
chmod +x install_acme.sh && sudo ./install_acme.sh
```

### `install_wildcard_ssl.sh`
Issues and installs a wildcard SSL certificate for a given domain. Requires `install_acme.sh` to have been run first.

```bash
sudo ./install_wildcard_ssl.sh <yourdomain.com>
```

### `install_phpmyadmin.sh`
Downloads the latest phpMyAdmin release and installs it to `/var/www/html/phpmyadmin`. Generates a random `blowfish_secret` and sets up basic configuration. Does not configure Nginx.

```bash
chmod +x install_phpmyadmin.sh && sudo ./install_phpmyadmin.sh
```

## Configuration

Scripts read from a `.env` file in the same directory. Copy `.env.example` to `.env` and fill in values before running:

```bash
cp .env.example .env
```

Required `.env` variables:
- `ACME_EMAIL` — email for Let's Encrypt registration
- `CF_Token` — Cloudflare API token with DNS edit permissions

Optional `.env` variables:
- `SSL_DIR` — certificate install path (defaults to `/etc/nginx/ssl`)

## Architecture

Both scripts follow the same pattern:
1. Require root (`EUID == 0`)
2. Load `.env` from the script's directory (`SCRIPT_DIR`)
3. Perform their function
4. Certificates are installed to `$SSL_DIR` and auto-renewal is handled via cron by acme.sh

The Cloudflare token is stored in acme.sh's `account.conf` as `SAVED_CF_Token` for use by the `dns_cf` DNS plugin during certificate issuance and renewal.

## Security Rules (Public Repository)

Since this repo is public, follow these rules strictly:

- **Never commit `.env`** — it is gitignored. Only `.env.example` (with placeholder values) belongs in the repo.
- **Never hardcode secrets** — no API tokens, emails, passwords, or real domain names in any script or documentation.
- **Never log sensitive values** — do not add `echo` or debug output that prints `CF_Token` or other credentials.
- **`.env` loading via `xargs`** — the current `export $(grep -v '^#' "$ENV_FILE" | xargs)` pattern is intentional but fragile with special characters; do not simplify it in a way that exposes values to `ps` or shell history.
- **Cloudflare token scope** — when documenting or advising on `CF_Token`, the token should have only `Zone:DNS:Edit` permission scoped to the relevant zone, not global API key.
- **Do not add execution via remote pipe** — avoid patterns like `curl ... | bash` beyond the existing acme.sh installer call, which is an upstream requirement.

## Target Environment

Scripts target **Debian/Ubuntu Linux** servers (use `apt-get`). They must run as root and expect `nginx` as the web server for certificate reloading.

## Commit Message Convention

This repo uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <short summary>

[optional body]
```

### Types

| Type       | When to use |
|------------|-------------|
| `feat`     | New script, feature, or capability |
| `fix`      | Bug fix or broken behaviour |
| `chore`    | Maintenance, dependency updates, config tweaks |
| `docs`     | README, CLAUDE.md, comments only |
| `refactor` | Code restructure without behaviour change |
| `ci`       | CI/CD pipeline changes |
| `revert`   | Reverting a previous commit |

### Examples

```
feat: add auto-renewal notification script
fix: remove --ocsp-must-staple flag (unsupported since Dec 2024)
docs: add Cloudflare token scope guidance to README
chore: update .env.example with SSL_DIR variable
```
