# FortiClient-EMS v7.4.x Self-Hosted Let's Encrypt DNS-01

Automates Let's Encrypt DNS-01 certificate issuance and renewal for FortiClient EMS v7.4.x on Ubuntu 24.04 without exposing inbound HTTP validation.

This workflow uses:

- Let's Encrypt DNS-01
- Cloudflare DNS API
- Certbot on the EMS host
- deployment into the EMS Apache certificate path

## What This Solves

FortiClient EMS can use a Let's Encrypt certificate for GUI and endpoint-control traffic, but the built-in ACME flow expects inbound HTTP validation.

This project replaces that with a DNS-01 flow and a deployment sequence that keeps the renewed certificate in the EMS runtime path.

## Requirements

- FortiClient EMS v7.4.x
- Ubuntu 24.04
- Cloudflare as the authoritative DNS provider
- a Cloudflare API token with:
  - `Zone:DNS:Edit`
  - `Zone:Zone:Read`

Use a token scoped only to the required zone.

## Runtime Paths

Let's Encrypt source of truth:

- `/etc/letsencrypt/live/<domain>/fullchain.pem`
- `/etc/letsencrypt/live/<domain>/privkey.pem`

EMS runtime certificate:

- `/opt/forticlientems/data/certs/<domain>.crt`
- `/opt/forticlientems/data/certs/<domain>.key`

## Installation

Copy this repo to the EMS host and run:

```bash
chmod +x scripts/setup.sh scripts/reload-ems.sh
sudo ./scripts/setup.sh --domain ems.example.com --email admin@example.com
```

This installs and creates:

- `certbot`
- `python3-certbot-dns-cloudflare`
- `/root/.secrets/certbot/cloudflare.ini`
- `/usr/local/sbin/fcems-certbot.sh`
- `/usr/local/sbin/fcems-ems-refresh.sh`
- `/etc/letsencrypt/renewal-hooks/deploy/fcems-cert-deploy.sh`

## Cloudflare Credentials

Edit the generated token file:

```bash
sudoedit /root/.secrets/certbot/cloudflare.ini
```

Example:

```ini
dns_cloudflare_api_token = REPLACE_ME
```

## First Production Issue

Issue the certificate:

```bash
sudo /usr/local/sbin/fcems-certbot.sh issue
```

Verify the live cert:

```bash
sudo /usr/local/sbin/fcems-certbot.sh verify
```

## Normal Renewal Flow

Normal renewals do not require an EMS restart.

Use Certbot’s scheduled timer or run manually:

```bash
sudo /usr/local/sbin/fcems-certbot.sh renew
sudo /usr/local/sbin/fcems-certbot.sh verify
```

That path:

- renews through DNS-01
- deploys the renewed cert into the EMS cert path
- reloads Apache

## Optional EMS Refresh Path

If you want to refresh the EMS suite for metadata or UI reasons, use:

```bash
sudo /usr/local/sbin/fcems-certbot.sh restart-ems-then-deploy
sudo /usr/local/sbin/fcems-certbot.sh verify
```

This path:

1. restarts enabled `fcems_*` services
2. waits for the restart burst to settle
3. deploys the current Let's Encrypt cert into the EMS cert path
4. reloads Apache

This will incur downtime.

## Validation Commands

Check the real EMS hostname:

```bash
echo | openssl s_client -connect ems.example.com:443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Check the fileserver port:

```bash
echo | openssl s_client -connect 127.0.0.1:10443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Check the deployed EMS file directly:

```bash
sudo openssl x509 -in /opt/forticlientems/data/certs/ems.example.com.crt -noout -subject -issuer -dates
```

## Important Note

EMS can still show an expired or stale certificate warning in the GUI even when Apache is serving the renewed certificate correctly.

Treat the live certificate presented on `443` and `10443` as the source of truth. If `verify` shows the renewed certificate, the remaining GUI warning is cosmetic.

Also note:

- restarting EMS after certificate deployment can cause EMS to rewrite the cert files
- if you need to restart EMS, do it first and deploy the certificate afterward

## Repo Contents

- `scripts/setup.sh`: installs the host-side automation
- `scripts/reload-ems.sh`: standalone restart/deploy helper
- `templates/cloudflare.ini.example`: token template

## Notes

- Cloudflare-only by design
- Ubuntu 24.04-focused by design
- Apache warnings about `${REDHAT_ARCH}` are noisy but harmless in this workflow
