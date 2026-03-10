# FortiClient-EMS v7.4.x - Self Hosted - Let's Encrypt DNS01 Validation

Automates Let's Encrypt DNS-01 certificate issuance and renewal for self-hosted FortiClient EMS v7.4.x on Ubuntu 24.04, using Cloudflare DNS.

This avoids inbound HTTP ACME validation entirely. Certbot obtains the certificate through DNS-01, then deploys the renewed certificate into the EMS certificate path used by Apache on ports `443` and `10443`.

## What This Solves

- EMS built-in ACME renewal depends on HTTP validation.
- Some deployments do not allow inbound internet access to EMS.
- DNS-01 validation removes the need to expose `80/443` publicly.

## Known Caveat

EMS can continue showing a stale warning in the GUI even when the live certificate presented by Apache has already been updated.

That warning appears to be EMS metadata/UI state, not the active TLS certificate. In practice:

- `apache2` serves the live cert for GUI/API traffic.
- EMS may not refresh the certificate warning immediately from filesystem changes.
- Reloading or restarting EMS-related services may clear the GUI warning, but this is typically aesthetic only if the live cert is already correct.

Always verify the live cert directly:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
echo | openssl s_client -connect 127.0.0.1:10443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

## Assumptions

- FortiClient EMS v7.4.x
- Ubuntu 24.04
- Apache-managed EMS frontend
- EMS certificate files stored at:
  - `/opt/forticlientems/data/certs/ems.example.com.crt`
  - `/opt/forticlientems/data/certs/ems.example.com.key`
- Cloudflare hosts the authoritative DNS for the EMS hostname

## Required Credentials

Cloudflare API token with access limited to the target zone:

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

Recommended scope: only the required zone, not all zones.

## Repo Layout

- `scripts/setup.sh`: installs certbot and writes the deployment tooling on the EMS host
- `scripts/reload-ems.sh`: optional reload/restart helper
- `templates/cloudflare.ini.example`: sample Cloudflare credential file

## Install

Copy the repo to the EMS host, then run:

```bash
chmod +x scripts/setup.sh scripts/reload-ems.sh
sudo ./scripts/setup.sh \
  --domain ems.example.com \
  --email admin@example.com
```

This will:

- install `certbot` and `python3-certbot-dns-cloudflare`
- create `/root/.secrets/certbot/cloudflare.ini`
- create `/etc/letsencrypt/renewal-hooks/deploy/fcems-cert-deploy.sh`
- create `/usr/local/sbin/fcems-certbot.sh`
- enable the standard `certbot.timer`

## Configure Cloudflare Token

Edit the generated credential file:

```bash
sudoedit /root/.secrets/certbot/cloudflare.ini
```

Replace `REPLACE_ME` with the real token.

## First Production Issue

Do not use `--staging` on a live system unless you also disable deployment.

Issue the first real certificate:

```bash
sudo /usr/local/sbin/fcems-certbot.sh issue
```

The wrapper uses the domain and email captured during setup.

## Dry Run Renewal

```bash
sudo /usr/local/sbin/fcems-certbot.sh renew-dry-run
```

This uses Let's Encrypt staging for renewal simulation, but the deploy hook in this repo explicitly refuses to deploy staging certificates into EMS.

## Optional EMS Reload / Restart

If the EMS GUI still shows a stale warning after a successful production renewal, you can optionally reload or restart services.

Lightest option:

```bash
sudo ./scripts/reload-ems.sh apache
```

Heavier option:

```bash
sudo ./scripts/reload-ems.sh monitor
```

Heaviest option:

```bash
sudo ./scripts/reload-ems.sh all
```

Notes:

- `apache` is the recommended default and usually enough for live TLS.
- `monitor` or `all` may help clear stale GUI metadata.
- `all` will incur visible EMS downtime and should be treated as an operational maintenance action.
- If the GUI warning persists while `openssl s_client` shows the correct certificate, the issue is cosmetic/UI state rather than live TLS.

## Recovery If You Accidentally Deployed a Staging Cert

Delete the lineage and re-issue production:

```bash
sudo certbot delete --cert-name ems.example.com
sudo /usr/local/sbin/fcems-certbot.sh issue
```

Then verify the issuer no longer contains `(STAGING)`.

## Validation Checklist

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
echo | openssl s_client -connect 127.0.0.1:10443 -servername ems.example.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
sudo systemctl status certbot.timer --no-pager
sudo certbot certificates
```

## Notes

- This project is intentionally Cloudflare-only.
- The deployed hook uses atomic temp-file replacement before reloading Apache.
- The hook refuses to deploy Let's Encrypt staging certificates.
- The Apache warning about `${REDHAT_ARCH}` seen on some EMS systems is noisy but not fatal for certificate deployment.
