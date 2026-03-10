# FortiClient-EMS v7.4.x Self-Hosted Let's Encrypt DNS-01

Operational runbook and automation for FortiClient EMS v7.4.x on Ubuntu 24.04 where inbound HTTP validation is not allowed.

This solution uses:

- Let's Encrypt DNS-01
- Cloudflare DNS API
- Certbot on the EMS host
- final certificate deployment into the EMS Apache certificate path

## Executive Summary

FortiClient EMS can use a Let's Encrypt certificate for the GUI and endpoint-control traffic, but its built-in ACME flow expects inbound HTTP validation.

This project replaces that with a DNS-01 flow and a tested deployment sequence.

Verified on a live EMS host:

- Apache is the real TLS frontend on `443` and `10443`
- the live certificate files are:
  - `/opt/forticlientems/data/certs/<domain>.crt`
  - `/opt/forticlientems/data/certs/<domain>.key`
- Certbot can safely maintain the real certificate under:
  - `/etc/letsencrypt/live/<domain>/fullchain.pem`
  - `/etc/letsencrypt/live/<domain>/privkey.pem`
- EMS can overwrite the deployed cert files during an EMS restart
- the stable sequence is:
  1. restart EMS first, if needed
  2. wait for EMS to settle
  3. deploy the renewed certificate last
  4. reload Apache

That sequence was tested live and remained stable after an immediate verification and another verification about 10 minutes later.

## Important EMS Behavior

EMS appears to track certificate metadata internally.

On the tested system:

- `fcm.public.server_certs` contained the ACME-backed certificate record
- `fcm.public.system_settings.webserver_cert_id` and `ec_cert_id` pointed to that record
- the stored EMS record still referenced the old expired ACME certificate

Practical effect:

- the GUI can show a stale warning even when Apache is serving the correct renewed cert
- restarting EMS after deployment can cause EMS to rewrite the cert files back to the older DB-backed value

Because of that, the safe automation rule is simple:

**never restart EMS after certificate deployment unless you are prepared to deploy the certificate again**

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
```

That path:

- renews through DNS-01
- deploys the renewed cert into the EMS cert path
- reloads Apache

## Optional EMS Refresh Path

If you want to refresh the EMS suite for metadata or UI reasons, use the tested safe order:

```bash
sudo /usr/local/sbin/fcems-certbot.sh restart-ems-then-deploy
sudo /usr/local/sbin/fcems-certbot.sh verify
```

What it does:

1. restarts enabled `fcems_*` services
2. waits for the restart burst to settle
3. deploys the current Let's Encrypt cert into the EMS cert path
4. reloads Apache

This is the correct downtime-incurring path if you insist on an EMS restart.

## Validation Commands

Check the real EMS hostname on localhost:

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

## Recommended Admin Runbook

Initial setup:

```bash
sudo ./scripts/setup.sh --domain ems.example.com --email admin@example.com
sudoedit /root/.secrets/certbot/cloudflare.ini
sudo /usr/local/sbin/fcems-certbot.sh issue
sudo /usr/local/sbin/fcems-certbot.sh verify
```

Routine renewal:

```bash
sudo /usr/local/sbin/fcems-certbot.sh renew
sudo /usr/local/sbin/fcems-certbot.sh verify
```

If you want an EMS refresh anyway:

```bash
sudo /usr/local/sbin/fcems-certbot.sh restart-ems-then-deploy
sudo /usr/local/sbin/fcems-certbot.sh verify
```

## Repo Contents

- `scripts/setup.sh`: installs the host-side automation
- `scripts/reload-ems.sh`: standalone restart/deploy helper
- `templates/cloudflare.ini.example`: token template

## Notes

- Cloudflare-only by design
- Ubuntu 24.04-focused by design
- Apache warnings about `${REDHAT_ARCH}` are noisy but harmless in this workflow
- The normal admin path does not require any special staging workflow
