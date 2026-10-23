#!/usr/bin/env bash
# Update the existing thulem.com host. Run --check to prepare/verify without any network access.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${1:-}
if [[ -z "$target" || "$target" == --help ]]; then
  printf 'Usage: bash web/deploy.sh <ssh-host-alias>\n       bash web/deploy.sh --check\n'
  exit 0
fi
if [[ "$target" != --check && ! "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]]; then
  printf 'Invalid SSH host alias.\n' >&2
  exit 2
fi
for command in node npm python3 rsync tar; do command -v "$command" >/dev/null; done
node -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major<22 || (major===22 && minor<13)) throw Error("Node.js >=22.13 required")'
stage=$(mktemp -d /tmp/macclean-deploy.XXXXXX)
cleanup() {
  if [[ -S "$stage/control" ]]; then ssh -S "$stage/control" -O exit "$target" >/dev/null 2>&1 || true; fi
  rm -rf -- "$stage"
}
trap cleanup EXIT

printf 'Checking the server and website…\n'
(cd "$project_dir/web/server" && npm run check)
if ! (cd "$project_dir/web/server" && MACCLEAN_TEST_IN_PROCESS=1 npm test) > "$stage/tests.log" 2>&1; then
  cat "$stage/tests.log"
  exit 1
fi
tail -8 "$stage/tests.log"
if ! node "$project_dir/web/site/dev/check-i18n.mjs" > "$stage/i18n.log"; then cat "$stage/i18n.log"; exit 1; fi
node "$project_dir/web/site/dev/build-seo.mjs" --check
python3 "$project_dir/web/site/dev/check-seo.py"
bash -n "$project_dir/web/server/deploy/update-existing.sh"

mkdir "$stage/site" "$stage/server"
# Stage code/public assets only. Existing production data, environment, Caddy and systemd stay on the host.
rsync -rlt --exclude '.*' --exclude dev/ "$project_dir/web/site/" "$stage/site/"
rsync -rlt --exclude '.*' --exclude test/ --exclude deploy/ --exclude node_modules/ \
  --exclude README.md "$project_dir/web/server/" "$stage/server/"
cp "$project_dir/web/server/deploy/update-existing.sh" "$stage/update-existing.sh"
python3 - "$stage" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
rows = []
payload_paths = [root / 'update-existing.sh']
for name in ('site', 'server'):
    payload_paths.extend((root / name).rglob('*'))
for p in sorted(payload_paths):
    if p.is_symlink():
        raise SystemExit('Deployment payload must not contain symlinks')
    if p.is_file():
        name = p.relative_to(root).as_posix()
        if '\n' in name or '\\' in name:
            raise SystemExit('Unsupported deployment filename')
        rows.append(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + name + '\n')
(root / 'SHA256SUMS').write_text(''.join(rows))
print(f'Payload verified locally: {len(rows)} files')
PY
COPYFILE_DISABLE=1 tar -czf "$stage/payload.tar.gz" -C "$stage" site server update-existing.sh SHA256SUMS
mkdir "$stage/verify"
tar -xzf "$stage/payload.tar.gz" -C "$stage/verify"
(cd "$stage/verify" && shasum -a 256 --check SHA256SUMS > /dev/null)
if [[ "$target" == --check ]]; then
  printf 'Preparation passed. No server was contacted or changed.\n'
  exit 0
fi

for command in ssh scp; do command -v "$command" >/dev/null; done
# Authenticate in the user's terminal once; reuse the private SSH control socket for uploads.
ssh_options=(-o BatchMode=no -o StrictHostKeyChecking=yes -o ConnectTimeout=10
  -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$stage/control")
remote_stage="/tmp/macclean-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf 'Checking target %s…\n' "$target"
ssh "${ssh_options[@]}" "$target" 'set -eu
test -d /var/www/thulem.com
test -d /opt/macclean-server
test "$(systemctl show macclean-server -p WorkingDirectory --value)" = /opt/macclean-server
systemctl is-active --quiet macclean-server
if [ "$(id -u)" -ne 0 ]; then sudo -n true; fi'
ssh "${ssh_options[@]}" "$target" "umask 077; mkdir '$remote_stage'"
scp "${ssh_options[@]}" "$stage/payload.tar.gz" "$target:$remote_stage/payload.tar.gz"
ssh "${ssh_options[@]}" "$target" "set -eu
cd '$remote_stage'
tar --no-same-owner -xzf payload.tar.gz
sha256sum --check --quiet SHA256SUMS
if [ \"\$(id -u)\" -eq 0 ]; then
  bash '$remote_stage/update-existing.sh' '$remote_stage'
else
  sudo -n bash '$remote_stage/update-existing.sh' '$remote_stage'
fi
rm -rf -- '$remote_stage'"
printf 'Server and website deployed. The native app still needs a new DMG release to send usage events.\n'
