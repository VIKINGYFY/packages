#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$PACKAGE_DIR/root/usr/share/rpcd/ucode/luci.gecoosac"
FOOTER="$PACKAGE_DIR/tests/rpc-harness-footer.uc"
UCODE="${UCODE:-/home/vking/VK/imm-main/staging_dir/hostpkg/bin/ucode}"
TEST_ROOT="$(mktemp -d)"
HARNESS="$TEST_ROOT/harness.uc"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir "$TEST_ROOT/upload" "$TEST_ROOT/outside"
printf 'firmware\n' > "$TEST_ROOT/upload/image.bin"
printf 'keep\n' > "$TEST_ROOT/outside/keep.txt"

{
	sed \
		-e "s|^import { init_action, process_list } from 'luci.sys';$|function init_action(service, action) { return service == 'gecoosac' ? 0 : 1; } function process_list() { return []; }|" \
		-e "s|^import { cursor } from 'uci';$|let test_root = '$TEST_ROOT'; let configured_path = test_root + '/upload'; function cursor() { return { get: function(config, section, option) { return configured_path; } }; }|" \
		-e "/^return { 'luci.gecoosac': methods };$/d" \
		"$RPC"
	sed -n '1,$p' "$FOOTER"
} > "$HARNESS"

result="$("$UCODE" "$HARNESS")"
printf '%s\n' "$result" | jq -e '
	.invalid_action.success == false and
	.invalid_action.code == 2 and
	.start_action.success == true and
	.clear.success == true and
	.clear.deleted == 1 and
	.protected.success == false
' >/dev/null

[ ! -e "$TEST_ROOT/upload/image.bin" ]
[ -e "$TEST_ROOT/outside/keep.txt" ]
printf 'simulate-rpc: all assertions passed\n'
