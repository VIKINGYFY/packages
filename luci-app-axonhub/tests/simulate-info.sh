#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$PACKAGE_DIR/root/usr/share/rpcd/ucode/luci.axonhub"
UCODE="${UCODE:-/home/vking/VK/imm-main/staging_dir/hostpkg/bin/ucode}"
HARNESS="$(mktemp)"
trap 'rm -f "$HARNESS"' EXIT

[ -x "$UCODE" ] || {
	echo "ucode interpreter not found: $UCODE" >&2
	exit 1
}

sed \
	-e "s|^import { access, glob, popen, readfile, readlink, statvfs } from 'fs';$|function access(path, mode) { return path == '/usr/bin/axonhub' ? false : true; } function glob(pattern) { return []; } function popen(command) { return null; } function readlink(path) { return null; } function readfile(path) { return join(chr(10), [ 'dev1 /mnt/small ext4 rw 0 0', 'dev2 /mnt/large ext4 rw 0 0', 'dev3 /tmp ext4 rw 0 0', 'dev4 /mnt/bad:path ext4 rw 0 0' ]); } function statvfs(path) { return path == '/mnt/large' ? { totalsize: 137438953472, freesize: 107374182400 } : { totalsize: 34359738368, freesize: 17179869184 }; }|" \
	-e "s|^import { init_action, process_list } from 'luci.sys';$|function init_action(service, action) { return 0; } function process_list() { return []; }|" \
	-e "/^return { 'luci.axonhub': methods };$/d" \
	"$RPC" > "$HARNESS"

echo 'print(methods.info.call());' >> "$HARNESS"
result="$("$UCODE" "$HARNESS")"

echo "$result" | jq -e '
	(.mounts | length) == 2 and
	.mounts[0].path == "/mnt/large" and
	.mounts[0].total == 137438953472 and
	.mounts[1].path == "/mnt/small" and
	(.recommended | not)
' >/dev/null

echo 'simulate-info: all assertions passed'
