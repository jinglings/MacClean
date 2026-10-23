#!/usr/bin/env bash
# Runs on the existing Ubuntu host as root, from a checksummed staging directory.
set -euo pipefail

[[ $(id -u) -eq 0 ]] || { printf 'Root or passwordless sudo is required.\n' >&2; exit 1; }
stage=$(realpath "${1:?Missing deployment stage}")
[[ "$stage" == /tmp/macclean-deploy-* && -d "$stage/site" && -d "$stage/server" ]]
site=/var/www/thulem.com
server=/opt/macclean-server
service=macclean-server
[[ -d "$site" && ! -L "$site" && -d "$server" && ! -L "$server" ]]
[[ $(systemctl show "$service" -p WorkingDirectory --value) == "$server" ]]
systemctl is-active --quiet "$service"
for command in flock rsync curl cp sha256sum; do command -v "$command" >/dev/null; done
exec 9>/var/lock/macclean-web-deploy.lock
flock -n 9 || { printf 'Another MacClean deployment is running.\n' >&2; exit 1; }
(cd "$stage" && sha256sum --check --quiet SHA256SUMS)

pid=$(systemctl show "$service" -p MainPID --value)
[[ "$pid" =~ ^[1-9][0-9]*$ ]]
node_bin=$(readlink -f "/proc/$pid/exe")
"$node_bin" -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<22||(a===22&&b<13)) throw Error("Node.js >=22.13 required")'
for file in "$stage"/server/src/*.js "$stage"/server/src/routes/*.js "$stage"/server/admin/js/*.js "$stage"/server/admin/js/pages/*.js; do
  "$node_bin" --check "$file"
done

backup="/var/backups/macclean-web/usage-$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -m 700 "$backup"
# Read just the running service's deployment settings; never print or copy its credentials.
"$node_bin" - "$pid" "$backup/runtime.json" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const [pid, output] = process.argv.slice(2);
const entries = fs.readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0');
const env = Object.fromEntries(entries.filter(s => s.includes('=')).map(s => [s.slice(0,s.indexOf('=')),s.slice(s.indexOf('=')+1)]));
const dataDir = fs.realpathSync(path.resolve('/opt/macclean-server', env.DATA_DIR || '/var/lib/macclean'));
if (['/opt/macclean-server','/var/www/thulem.com'].some(p => dataDir === p || dataDir.startsWith(p+'/'))) throw Error('Data directory must be outside deployed code');
const dbPath = path.join(dataDir, 'macclean.db');
if (!fs.statSync(dbPath).isFile()) throw Error('Production database is missing');
const port = Number(env.PORT) || 8787;
if (port < 1 || port > 65535) throw Error('Invalid service port');
fs.writeFileSync(output, JSON.stringify({ dbPath, port }), {mode:0o600});
JS
printf 'Backing up to %s\n' "$backup"
cp -a "$site" "$backup/site"
cp -a "$server" "$backup/server"

changed=0
stopped=0
rollback() {
  result=$?
  trap - EXIT
  if [[ "$result" -ne 0 ]]; then
    printf 'Deployment failed; restoring the previous code. Backup: %s\n' "$backup" >&2
    if [[ "$changed" -eq 1 ]]; then
      systemctl stop "$service" || true
      rsync -a --delete "$backup/server/" "$server/" || true
      rsync -a --delete "$backup/site/" "$site/" || true
    fi
    if [[ "$stopped" -eq 1 ]]; then systemctl start "$service" || true; fi
    # Migration 2 is additive and old code can run against it. Never discard newer orders
    # by restoring an older database automatically. The consistent DB snapshot is retained.
  fi
  exit "$result"
}
trap rollback EXIT
systemctl stop "$service"
stopped=1
"$node_bin" --disable-warning=ExperimentalWarning - "$backup" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const dir = process.argv[2];
const runtime = JSON.parse(fs.readFileSync(path.join(dir,'runtime.json'),'utf8'));
const db = new DatabaseSync(runtime.dbPath);
if (db.prepare('PRAGMA quick_check').get().quick_check !== 'ok') throw Error('Database check failed before deployment');
const counts = Object.fromEntries(['orders','licenses','activations','releases'].map(t => [t,db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get().n]));
db.prepare('VACUUM INTO ?').run(path.join(dir,'macclean.db'));
db.close();
fs.writeFileSync(path.join(dir,'counts.json'),JSON.stringify(counts),{mode:0o600});
JS
changed=1
# Overlay the payload; do not delete unrelated public files, configuration or uploaded DMGs.
rsync -rlt --chmod=D755,F644 "$stage/server/" "$server/"
rsync -rlt --chmod=D755,F644 "$stage/site/" "$site/"
systemctl start "$service"
port=$("$node_bin" -p "JSON.parse(require('fs').readFileSync('$backup/runtime.json','utf8')).port")
healthy=0
for attempt in {1..15}; do
  if curl --fail --silent --max-time 3 "http://127.0.0.1:$port/api/health" > "$backup/health.json"; then healthy=1; break; fi
  sleep 1
done
[[ "$healthy" -eq 1 ]]
"$node_bin" -e 'if(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).ok!==true) process.exit(1)' "$backup/health.json"
code=$(curl --silent --show-error --max-time 10 -o "$backup/usage-probe.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/usage/events")
[[ "$code" == 400 ]]
"$node_bin" --disable-warning=ExperimentalWarning - "$backup" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const dir = process.argv[2];
const {dbPath} = JSON.parse(fs.readFileSync(path.join(dir,'runtime.json'),'utf8'));
const old = JSON.parse(fs.readFileSync(path.join(dir,'counts.json'),'utf8'));
const db = new DatabaseSync(dbPath,{readOnly:true});
if (db.prepare('SELECT version FROM schema_version').get().version < 2) throw Error('Usage migration did not run');
db.prepare('SELECT COUNT(*) FROM usage_events').get();
for (const [table,count] of Object.entries(old)) {
  if (db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n < count) throw Error(`${table} count decreased`);
}
if (db.prepare('PRAGMA quick_check').get().quick_check !== 'ok') throw Error('Database check failed');
db.close();
JS
for page in download.html en/download.html privacy.html en/privacy.html; do
  output="$backup/$(printf '%s' "$page" | tr / _)"
  curl --fail --silent --show-error --location --max-time 20 \
    "https://thulem.com/$page?deployment=$(basename "$backup")" > "$output"
  if [[ "$page" == *download.html ]]; then
    grep -q 'data-i18n="dl.noticeH"' "$output"
    grep -q 'data-i18n="dl.warningH"' "$output"
  else
    grep -q 'data-i18n="pv.net5"' "$output"
  fi
done
systemctl is-active --quiet "$service"
systemctl is-active --quiet caddy
printf 'Deployment and public checks passed. Backup: %s\n' "$backup"
