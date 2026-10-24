# thulem.com: MacClean website + license server (spec)

Domain: https://thulem.com (behind Cloudflare). Server: Ubuntu 24.04, Caddy already serves :80/:443.
**Never touch** x-ui / xray / frps (the proxy services) on that box.

## Repo layout

```
web/
  SPEC.md            ← this file (the contract both sides follow)
  site/              ← static website (HTML/CSS/JS, no build step required), deployed to /var/www/thulem.com
  server/            ← Node.js 22 backend, zero npm dependencies (node:http + node:sqlite + node:crypto)
    src/…            deployed to /opt/macclean-server, runs as systemd service on 127.0.0.1:8787
    admin/…          admin SPA (static files served by the backend under /admin/)
    test/…           node --test
```

Caddy routes: `/api/*`, `/admin*`, `/appcast.xml`, `/download/*`, `/files/*` → `reverse_proxy 127.0.0.1:8787`; everything else → static `site/`.

## Current policy (MacClean 1.6, 2026-10-24)

Personal and internal business use, deployment and modifications are free, with all features included, no trial, device limit or activation. Selling original/modified copies or integrating code into a paid product requires a separate written paid commercial agreement. See `../LICENSE`. This is a community source-available license, not OSI open source. The repository is public at https://github.com/jinglings/MacClean. Public config reports sourcePublic: true and sourceUrl.

Production `salesEnabled` defaults to false and is not enabled through an environment variable. Public config returns `salesEnabled: false`, `plans: []`, empty payment details and license policy metadata. `POST /api/orders` returns 410 without creating a record. Historical order lookup, refunds, the admin desk and old client license endpoints remain compatible. The order creation contract below describes legacy behavior exercised only by explicit test overrides.

## Product facts (use these in copy)

MacClean: a local-only macOS disk cleaning and maintenance app, for macOS 14+ on Apple silicon and Intel. Chinese and English UI.
Features (tab names in zh / en):
- 一键体检 Checkup: junk, duplicates, large files and broken login items in one scan
- 存储地图 Storage Map: drill-down visualization of the whole disk
- 释放空间 Reclaim Space: app/browser caches, logs older than 7 days, installers, Mail attachments, iOS backups and firmware, Trash
- 大型与陈旧文件 Large & Old Files
- 相似照片 Similar Photos: bursts, re-exports, and lightly cropped or compressed copies; keeps the best shot
- 开发缓存 Dev Caches: Xcode DerivedData and simulators, npm/pip/Gradle/Cargo, node_modules in idle projects
- 隐私清理 Privacy: Safari/Chrome/Edge/Brave/Firefox history, cookies and sessions; never bookmarks or passwords
- 启动项 Login Items: launch agents/daemons, apps that open at login, broken leftovers
- 系统维护 Maintenance: flush DNS, rebuild Spotlight, rebuild the Open With database, delete Time Machine local snapshots, purge, restart Dock/Finder
- 应用占用 App Storage: real size per app, including WeChat/QQ chat data and Docker disks
- 应用管家 App Manager: full uninstall with leftovers, update check for Sparkle apps, orphaned leftovers, installers
- 文件搜索 File Search: Spotlight plus its own index
- Menu bar panel: disk, memory, battery health, CPU, network speed test, Bluetooth device batteries
Safety: ordinary file cleanup moves files to the Trash and supports Cleanup History recovery before emptying it. Emptying Trash, Docker cleanup and snapshot deletion have separate irreversible-operation warnings. PathGuard protects system and user folders; scans are read-only. File information stays local; optional first-party usage reporting is off by default. No account is required.
Honesty rule: never claim "speeds up your Mac", no fake scare numbers.
Legacy personal plans (¥98 / ¥168) are retained for historical records only. New daily-use purchases are closed. Commercial distribution terms are agreed separately.

## Public API (JSON, UTF-8)

Errors: `{ "error": "message" }` with 4xx/5xx. All POST bodies accept `application/json`; the license endpoints ALSO accept `application/x-www-form-urlencoded` (the app sends form-encoded).

### Site config
`GET /api/public/config` →
```json
{ "plans": [{ "id": "lifetime", "name": "终身版", "nameEn": "Lifetime", "price": 98, "currency": "CNY", "devices": 2, "features": ["…"], "highlight": true }],
  "payment": { "wechatQr": "/files/qr-wechat.png" | null, "alipayQr": "/files/qr-alipay.png" | null, "instructions": "…" },
  "contactEmail": "…", "announcement": "…" | null,
  "latestRelease": { "version": "1.0", "build": "1", "minOS": "14.0", "size": 12345678, "notes": "markdown/plain", "publishedAt": "ISO", "downloadUrl": "/download/latest" } | null }
```

### Historical orders (new production orders closed)
`POST /api/orders` `{ "plan": "lifetime", "email": "a@b.com", "payMethod": "wechat"|"alipay", "note": "optional" }` →
`201 { "orderNo": "MC20261001-7K3Q", "amount": 98, "payMethod": "wechat", "payCode": "7K3Q", "status": "pending", "accessToken": "<random 24 chars>" }`
- `payCode` = short code the buyer must write in the payment remark (备注) so the admin can match the payment.
- Rate limit: 5 orders/IP/hour. Validate email format and that the plan exists.

`GET /api/orders/:orderNo?token=<accessToken>` (or `?email=` matching the order email) →
`{ orderNo, plan, planName, amount, payMethod, payCode, status: "pending"|"paid"|"cancelled", createdAt, paidAt, licenseKey: "MCLN-XXXX-XXXX-XXXX-XXXX" | null, devices }`
`licenseKey` only when paid. Return 404 for wrong token or email (don't leak existence).

`POST /api/orders/:orderNo/notify` `{ token }` → buyer says "I've paid", sets `buyerNotifiedAt` (shows as highlighted in admin). Rate limited.

### License API (compatible with the LemonSqueezy License API, which the macOS app already speaks)
Base: `POST /api/licenses/{activate|validate|deactivate}`, form-encoded or JSON.
- activate: `license_key, instance_name` → `200 {"activated":true,"error":null,"license_key":{"status":"active","activation_limit":2,"activation_usage":1},"instance":{"id":"<uuid>","name":"…"},"meta":{"store_id":1,"product_id":1,"product_name":"MacClean","variant_name":"终身版"}}`
  - unknown key → `404 {"activated":false,"error":"license_key not found"}`
  - disabled/revoked key → `400 {"activated":false,"error":"This license key is disabled.","license_key":{"status":"disabled",…}}`
  - limit reached → `400 {"activated":false,"error":"This license key has reached the activation limit.","license_key":{…}}`
- validate: `license_key, instance_id` → `200 {"valid":true,"error":null,"license_key":{…},"instance":{…},"meta":{…}}`; unknown key/instance → `404 {"valid":false,"error":"license_key not found"}` (or `"instance not found"`); disabled → `200 {"valid":false,"license_key":{"status":"disabled"…}}`
- deactivate: `license_key, instance_id` → `200 {"deactivated":true,"error":null,"license_key":{…},"meta":{…}}`; unknown → 404 like above.
- Record last_seen_at / app version (optional `app_version` param) on each call. Rate limit per IP: 60/hour.
License key format: `MCLN-` + 4 groups of 4 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.

### Downloads & updates
- `GET /download/latest` → 302 to `/files/releases/MacClean-<version>.dmg`, increments download count (count unique IP per day separately).
- `GET /files/*` → serves uploaded files (dmg, QR images) from the data dir, with correct Content-Type, Content-Length, and Range support for dmg.
- `GET /appcast.xml` → Sparkle 2 appcast generated from releases that have an `edSignature`: `<item>` with `<title>`, `<pubDate>`, `<sparkle:version>` (build), `<sparkle:shortVersionString>`, `<sparkle:minimumSystemVersion>`, `<description><![CDATA[notes]]></description>`, `<enclosure url="https://thulem.com/files/releases/…" length type="application/octet-stream" sparkle:edSignature="…"/>`.

### Admin (`/admin/`, SPA + `/api/admin/*`)
- Auth: single admin account. Password from the env var `ADMIN_PASSWORD_HASH` (scrypt `salt:hash`) or a first-run setup (if unset, create the password on first visit, only from localhost or with a one-time setup token printed to the journal). Session = HttpOnly Secure SameSite=Strict cookie, 7 days, stored server-side. Login rate limit: 10 tries/15 min/IP. CSRF: require the `X-Requested-With: macclean-admin` header on mutating requests.
- `GET /api/admin/stats` → totals (orders pending/paid, revenue, licenses, active devices, downloads today/7d/total) + daily series for 30 days (orders, revenue, downloads, activations).
- Orders: list with filters (status, search email/orderNo/payCode) and pagination; `POST /api/admin/orders/:no/confirm` (marks paid, generates the license with the plan's device limit, returns the key); `/cancel`; `/note`.
- Licenses: list/search; `POST /api/admin/licenses` (manually issue: email, plan, devices, note); `/:key/disable`, `/:key/enable`; `GET /:key` with activations (instance name, app version, first/last seen); `DELETE /api/admin/licenses/:key/activations/:id` (free a slot).
- Releases: list; `POST /api/admin/releases` multipart upload (dmg + version + build + minOS + notes + optional edSignature), max 500 MB, streamed to disk; set latest; delete.
- Settings: plans (name, nameEn, price, devices, features[], highlight), payment instructions, QR image upload (wechat/alipay), contact email, announcement; change password.
- Audit log of admin actions.

## Storage
SQLite at `/var/lib/macclean/macclean.db` (WAL); files in `/var/lib/macclean/files/` (`releases/`, `qr-*.png`). Daily DB backup to `/var/lib/macclean/backups/` (keep 14).

## Security baseline
Bind 127.0.0.1 only; trust `CF-Connecting-IP` / `X-Forwarded-For` only from 127.0.0.1 (Caddy). Parameterized SQL only. Body size limits (64 KB JSON; uploads only via admin). No user HTML rendered (escape everything in the admin UI). Constant-time compare for tokens and passwords.
