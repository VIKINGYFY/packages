#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$PACKAGE_DIR/root/etc/init.d/wolultra"
TEST_ROOT="$(mktemp -d)"
CRONTAB="$TEST_ROOT/root"
LOCKFILE="$TEST_ROOT/wolultra.lock"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[ "$expected" = "$actual" ] || fail "$message (expected $expected, got $actual)"
}

assert_contains() {
	local needle="$1"
	local file="$2"
	grep -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
}

lock() {
	if [ "${1:-}" = '-u' ]; then
		flock -u 9
		exec 9>&-
	else
		exec 9>"$LOCKFILE"
		flock 9
	fi
}

logger() {
	return 0
}

config_load() {
	return 0
}

config_get() {
	local destination="$1"
	local section="$2"
	local option="$3"
	local default="${4:-}"
	local variable="CFG_${section}_${option}"
	local value="${!variable-$default}"
	printf -v "$destination" '%s' "$value"
}

config_foreach() {
	local callback="$1"
	local type="$2"
	shift 2
	local section section_type

	for section in ${CFG_SECTIONS:-}; do
		section_type="CFG_${section}_TYPE"
		[ "${!section_type-}" = "$type" ] || continue
		"$callback" "$section" "$@"
	done
}

# Load the installed script's functions, then replace the cron daemon action.
source <(sed -e '1,3d' "$INIT")

CRON_FILE="$CRONTAB"
CRON_LOCK="$LOCKFILE"
CRON_RELOADS=0

reload_cron() {
	CRON_RELOADS=$((CRON_RELOADS + 1))
}

clear_config() {
	local variable
	for variable in ${!CFG_@}; do
		unset "$variable"
	done
	CFG_SECTIONS=''
}

add_client() {
	local section="$1"
	local scheduled="$2"
	local mac="$3"
	local iface="${4:-br-lan}"
	local minute="${5:-0}"
	local hour="${6:-0}"
	local day="${7:-*}"
	local month="${8:-*}"
	local weeks="${9:-*}"
	local name="${10:-$section}"

	CFG_SECTIONS="${CFG_SECTIONS:+$CFG_SECTIONS }$section"
	printf -v "CFG_${section}_TYPE" '%s' macclient
	printf -v "CFG_${section}_scheduled" '%s' "$scheduled"
	printf -v "CFG_${section}_name" '%s' "$name"
	printf -v "CFG_${section}_macaddr" '%s' "$mac"
	printf -v "CFG_${section}_maceth" '%s' "$iface"
	printf -v "CFG_${section}_minute" '%s' "$minute"
	printf -v "CFG_${section}_hour" '%s' "$hour"
	printf -v "CFG_${section}_day" '%s' "$day"
	printf -v "CFG_${section}_month" '%s' "$month"
	printf -v "CFG_${section}_weeks" '%s' "$weeks"
}

export_config() {
	local variable
	for variable in ${!CFG_@}; do
		export "$variable"
	done
}

rule_count() {
	grep -c '[[:space:]]# wolultra\([[:space:]].*\)\?$' "$CRONTAB" || true
}

clear_config
printf '17 3 * * * /usr/bin/example # unrelated\n' > "$CRONTAB"
printf '18 3 * * * /usr/bin/legacy # wolultra\n' >> "$CRONTAB"
printf '19 3 * * * /usr/bin/stale # wolultra Old NAS\n' >> "$CRONTAB"
printf '20 3 * * * /usr/bin/similar # wolultra-extra\n' >> "$CRONTAB"
add_client disabled 0 '00:11:22:33:44:50'
add_client workstation 1 '00:11:22:33:44:51' br-lan 30 7 '*' '*' '1' 'Office PC'
add_client wildcard yes '00:11:22:33:44:52' eth0 '*' '*' '*' '*' '*' 'Backup NAS'
rebuild_crontab config
assert_eq 2 "$(rule_count)" 'per-client scheduled switch'
assert_eq 1 "$CRON_RELOADS" 'changed crontab reloads cron once'
assert_contains '30 7 * * 1 /usr/bin/etherwake -b -D -i br-lan 00:11:22:33:44:51 # wolultra Office PC' "$CRONTAB"
assert_contains '* * * * * /usr/bin/etherwake -b -D -i eth0 00:11:22:33:44:52 # wolultra Backup NAS' "$CRONTAB"
assert_contains '/usr/bin/example # unrelated' "$CRONTAB"
assert_contains '/usr/bin/similar # wolultra-extra' "$CRONTAB"
if grep -Fq '/usr/bin/legacy # wolultra' "$CRONTAB" || grep -Fq '/usr/bin/stale # wolultra Old NAS' "$CRONTAB"; then
	fail 'legacy and stale detailed rules are removed during migration'
fi
assert_eq 600 "$(stat -c %a "$CRONTAB")" 'crontab permissions'

rebuild_crontab config
assert_eq 2 "$(rule_count)" 'idempotent reload'
assert_eq 1 "$CRON_RELOADS" 'unchanged crontab does not reload cron'

clear_config
add_client first 1 '00:11:22:33:44:61' br-lan 0 0 1 1 0
add_client bad_mac 1 'not-a-mac'
add_client bad_iface 1 '00:11:22:33:44:62' 'br-lan;reboot'
add_client bad_minute 1 '00:11:22:33:44:63' br-lan 60
add_client bad_hour 1 '00:11:22:33:44:64' br-lan 0 24
add_client bad_day 1 '00:11:22:33:44:65' br-lan 0 0 32
add_client bad_month 1 '00:11:22:33:44:66' br-lan 0 0 '*' 13
add_client bad_week 1 '00:11:22:33:44:67' br-lan 0 0 '*' '*' 7
add_client last 1 '00:11:22:33:44:68' br-lan 59 23 31 12 6
rebuild_crontab config
assert_eq 2 "$(rule_count)" 'invalid entries do not remove later valid entries'
assert_contains '59 23 31 12 6 /usr/bin/etherwake -b -D -i br-lan 00:11:22:33:44:68 # wolultra last' "$CRONTAB"

clear_config
for i in $(seq 1 150); do
	add_client "host$i" 1 "02:00:00:00:$(printf '%02x' $((i / 256))):$(printf '%02x' $((i % 256)))" br-lan "$((i % 60))" "$((i % 24))"
done
export_config
rebuild_crontab config
assert_eq 150 "$(rule_count)" 'all 150 clients are retained'

for _ in $(seq 1 50); do
	(rebuild_crontab config) &
done
wait
assert_eq 150 "$(rule_count)" 'concurrent reloads retain all clients'
assert_eq 1 "$(grep -c '/usr/bin/example # unrelated' "$CRONTAB")" 'concurrent reloads retain unrelated entries once'

rebuild_crontab disabled
assert_eq 0 "$(rule_count)" 'stop removes all wolultra rules'
assert_contains '/usr/bin/example # unrelated' "$CRONTAB"

printf 'simulate-init: all assertions passed\n'
