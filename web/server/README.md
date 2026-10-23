# MacClean server (thulem.com)

The license API (LemonSqueezy-compatible), the manual QR-payment order desk, downloads, the Sparkle appcast and the admin panel.
It needs Node.js ≥ 22.13 and has **zero npm dependencies** (`node:http`, `node:sqlite`, `node:crypto`). The API contract is in `../SPEC.md`.

```
src/        server (entry: src/main.js, CLI: src/cli.js)
admin/      admin SPA (vanilla JS, served at /admin/)
test/       node --test suites
deploy/     systemd unit, env example, Caddyfile snippet
```

## Run locally

```sh
cd web/server
NODE_ENV=development DATA_DIR=/tmp/macclean PORT=8787 node src/main.js
# open http://127.0.0.1:8787/admin/ and paste the SETUP TOKEN printed on stdout
npm test        # node --test, about 3 s
npm run check   # node --check on every server and admin JS file
```

`NODE_ENV=development` drops the `Secure` flag and the `__Host-` prefix from the session cookie so plain http works.

## Environment

| Variable | Default | |
|---|---|---|
| `HOST` / `PORT` | `127.0.0.1` / `8787` | Keep it on loopback; Caddy proxies to it. |
| `DATA_DIR` | `/var/lib/macclean` | `macclean.db` (SQLite, WAL), `files/releases/*.dmg`, `files/qr-*.png`, `backups/` |
| `PUBLIC_BASE_URL` | `https://thulem.com` | Used for appcast enclosure URLs and the URLs shown in the admin panel. |
| `ADMIN_PASSWORD_HASH` | unset | Optional `salt:hash` (scrypt). If set, it wins over the DB password, the setup screen is skipped and in-app password change is disabled. |
| `TIMEZONE` | `Asia/Shanghai` | Day boundaries for "today" and the 30-day charts. |
| `NODE_ENV` | | `development` relaxes the cookie flags (see above). |
| `ACCESS_LOG` | unset | `1` logs every `/api/*` request. |

## First-run admin setup

If no password exists (neither `ADMIN_PASSWORD_HASH` nor one in the DB), the server prints a one-time token at startup:

```sh
journalctl -u macclean-server | grep "SETUP TOKEN"
```

Open `https://thulem.com/admin/`, enter the token and choose a password (10+ characters). The token is used up on success.
A restart before setup prints a new token. Other ways to set the password:

```sh
cd /opt/macclean-server
sudo -u macclean DATA_DIR=/var/lib/macclean node src/cli.js set-password   # prompts; signs out all sessions
node src/cli.js hash-password                                              # prints a value for ADMIN_PASSWORD_HASH
```

## CLI (emergencies)

```sh
sudo -u macclean DATA_DIR=/var/lib/macclean node src/cli.js issue-license --email a@b.com --plan lifetime [--devices 2] [--note "…"]
sudo -u macclean DATA_DIR=/var/lib/macclean node src/cli.js backup
```

Run the CLI as `macclean` so that files it creates keep the right owner. It is safe to use while the server is running (SQLite WAL).

## Deploy (Ubuntu 24.04)

For **updating the existing production host**, run from the MacClean project on your Mac:

```sh
bash web/deploy.sh --check            # local preparation only, no network access
bash web/deploy.sh <ssh-host-alias>   # use the verified SSH alias for the thulem.com host
```

This uses existing SSH credentials and verified known-host keys; if needed SSH prompts for a
password in your local terminal. No password is embedded or saved by the script.
It checks the target's directories and service, verifies the upload with SHA-256, backs up the
current site/server and a consistent SQLite snapshot under `/var/backups/macclean-web/usage-*`,
updates code, restarts `macclean-server`, and verifies the endpoint, migration, retained records
and four public Chinese/English pages. The SSH user needs root or passwordless sudo.
Failures roll back code; the additive database migration stays compatible with the previous
server, so automatic rollback never overwrites orders received after the snapshot. Environment,
Caddy/systemd configuration and release DMGs are not replaced. The native app must still be
rebuilt and released separately for users to send usage events.

For the initial installation only:

```sh
sudo useradd --system --home /var/lib/macclean --shell /usr/sbin/nologin macclean
sudo install -d -o macclean -g macclean -m 750 /var/lib/macclean
sudo rsync -a --delete --exclude test --exclude .data web/server/ /opt/macclean-server/
sudo install -m 640 -o root -g macclean deploy/macclean-server.env.example /etc/macclean-server.env   # then edit
sudo cp deploy/macclean-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now macclean-server
curl -s http://127.0.0.1:8787/api/health      # {"ok":true}
```

Then merge `deploy/Caddyfile.snippet` into the `thulem.com` site block and run `caddy validate && systemctl reload caddy`.

### Things to know

- **Cloudflare upload limit.** Cloudflare's Free and Pro plans reject request bodies over 100 MB. That covers QR images and normal admin use, but a DMG over 100 MB can't be uploaded through the proxied domain. Upload big releases over an SSH tunnel: `ssh -L 8787:127.0.0.1:8787 server`, then open `http://localhost:8787/admin/` (browsers treat localhost as secure, so the `__Host-` cookie works). Another option is a DNS-only (grey-cloud) admin hostname.
- **Client IPs.** The backend trusts `CF-Connecting-IP` / `X-Forwarded-For` only when the TCP peer is 127.0.0.1. Rate limits and download uniqueness depend on `CF-Connecting-IP`. Firewall 80/443 to Cloudflare's IP ranges so nobody can reach Caddy directly with a forged header.
- **Caching.** `/api/public/config` sends `Cache-Control: public, max-age=60`, release DMGs `max-age=86400` (file names are versioned), and the appcast `max-age=300`. QR URLs carry `?v=<timestamp>`, so replacing a QR busts caches.
- **Sparkle.** Only releases with an EdDSA signature (`sign_update` output) appear in `/appcast.xml`. If an older release is marked latest (a rollback), newer releases are left out of the appcast.
- **Memory.** Uploads are streamed to disk. Peak RSS during a 50 MB upload was about 110 MB, within `MemoryMax=300M`.

## Backup and restore

Once a day (checked hourly, and at startup) the server writes `DATA_DIR/backups/macclean-YYYY-MM-DD.db` with `VACUUM INTO` and keeps the newest 14.
Backups cover the database only. Release DMGs and QR images live in `DATA_DIR/files/`, so copy that directory separately (for example `rsync` it off-box).

Restore:

```sh
sudo systemctl stop macclean-server
sudo -u macclean cp /var/lib/macclean/backups/macclean-2026-10-01.db /var/lib/macclean/macclean.db
sudo rm -f /var/lib/macclean/macclean.db-wal /var/lib/macclean/macclean.db-shm
sudo systemctl start macclean-server
```

## Endpoints

Public: `GET /api/health`, `GET /api/public/config`, `POST /api/orders`, `GET /api/orders/:no?token=|email=`, `POST /api/orders/:no/notify`,
`POST /api/licenses/{activate,validate,deactivate}` (form or JSON), `POST /api/usage/events` (opt-in native usage statistics),
`GET /download/latest`, `GET|HEAD /files/*` (Range), `GET /appcast.xml`.

Admin (session cookie; mutations need `X-Requested-With: macclean-admin`):
`GET /api/admin/session`, `POST /api/admin/{setup,login,logout,password}`, `GET /api/admin/stats`, `GET /api/admin/orders/summary`,
`GET /api/admin/orders`, `GET /api/admin/orders/:no`, `POST /api/admin/orders/:no/{confirm,cancel,note}`,
`GET|POST /api/admin/licenses`, `GET|PATCH /api/admin/licenses/:key`, `POST /api/admin/licenses/:key/{disable,enable}`,
`DELETE /api/admin/licenses/:key/activations/:id`, `GET|POST /api/admin/releases` (multipart), `PATCH|DELETE /api/admin/releases/:id`,
`POST /api/admin/releases/:id/latest`, `GET|PUT /api/admin/settings`, `POST|DELETE /api/admin/settings/qr/:kind`, `GET /api/admin/audit`.

## Voluntary usage statistics

Deploy the server and website before distributing the updated app. Startup appends migration 2 automatically;
existing orders, licenses and downloads remain intact. The dashboard adds a separate usage section.
No developer certificate is required for these events; signing/notarization remains a separate release task.

The app sends nothing until the user enables **Share usage statistics** in onboarding or Settings → General → Privacy.
It uses an app-local random UUID (not a hardware ID), persists retries for at most 30 days, and cancels uploads/clears
unsent events when disabled. Already-received records cannot be retracted by toggling the switch.
No scan history from before consent is reported. The UUID and sent-event deduplication markers remain locally
after disabling so re-enabling does not count a new installation.

`POST /api/usage/events` accepts JSON only in the following shape (max 40 events, rate-limited separately from licensing):

```json
{"installationId":"12345678-1234-4234-8234-123456789abc","events":[{"name":"first_open","occurredAt":"2026-10-23T08:00:00Z","appVersion":"1.2.0","osVersion":"26.0.1"}]}
```

Allowed events are `first_open`, `daily_active`, `first_scan`. The server deduplicates the first events per installation,
and active events per installation/business day (`TIMEZONE=Asia/Shanghai` by default, matching the client's daily boundary).
Event timestamps are UTC; the server rejects timestamps older than 35 days or more than 5 minutes in the future.
Installation IDs are HMAC-SHA256 hashed with a persistent server salt before storage. No IP, license key,
computer name, paths, file content, scan results or file counts enter the usage event table. Connections still
expose IP addresses to the hosting infrastructure; the existing operational access-log policy applies.

`GET /api/admin/stats` adds `usage` totals and `firstOpens`, `dailyActive`, `firstScans` to its daily series.
These are **opt-in observations, not total installs**. First reports may come from upgrades; cancelled/failed scans
do not count, successful empty scans do. `/download/latest` counts requests, not completed downloads.
Old builds cannot retrospectively report their installations. Test the new handler without opening a port:

```sh
node --disable-warning=ExperimentalWarning --test test/usage.test.js
# Full handler regression suite without binding local ports:
MACCLEAN_TEST_IN_PROCESS=1 npm test
```
