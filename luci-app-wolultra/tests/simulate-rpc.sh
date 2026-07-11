#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$PACKAGE_DIR/root/usr/share/rpcd/ucode/luci.wolultra"
FOOTER="$PACKAGE_DIR/tests/rpc-harness-footer.uc"
UCODE="${UCODE:-/home/vking/VK/imm-main/staging_dir/hostpkg/bin/ucode}"
HARNESS="$(mktemp)"
trap 'rm -f "$HARNESS"' EXIT

[ -x "$UCODE" ] || {
	printf 'ucode interpreter not found: %s\n' "$UCODE" >&2
	exit 1
}

{
	sed \
		-e "s|^import { init_action } from 'luci.sys';$|function init_action(service, action) { return service == 'wolultra' ? (action == 'reload' ? 0 : 1) : 1; }|" \
		-e "/^return { 'luci.wolultra': methods };$/d" \
		"$RPC"
	sed -n '1,$p' "$FOOTER"
} > "$HARNESS"

result="$("$UCODE" "$HARNESS")"

printf '%s\n' "$result" | jq -e '
	.invalid_mac.code == 1 and
	.invalid_mac.stderr == "invalid mac address" and
	.invalid_iface.code == 1 and
	.invalid_iface.stderr == "invalid interface" and
	.missing_binary.code == 127 and
	.missing_binary.stderr == "etherwake is not executable" and
	.sync.success == true and
	.sync.code == 0
' >/dev/null

printf 'simulate-rpc: all assertions passed\n'
