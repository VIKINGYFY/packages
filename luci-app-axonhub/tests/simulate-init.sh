#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$PACKAGE_DIR/root/etc/init.d/axonhub"
TEST_ROOT="$(mktemp -d)"
CRONTAB="$TEST_ROOT/root"
LOCKFILE="$TEST_ROOT/root-crontab.lock"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "$3 (expected $1, got $2)"
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

extra_command() { :; }
source "$INIT"
CRON_FILE="$CRONTAB"
CRON_LOCK="$LOCKFILE"
CRON_RELOADS=0

reload_cron() {
	CRON_RELOADS=$((CRON_RELOADS + 1))
}

printf '1 1 * * * /usr/bin/unrelated #keep\n' > "$CRONTAB"
printf '0 3 * * 0 /usr/libexec/axonhub-log-cleanup #axonhub\n' >> "$CRONTAB"
printf '2 2 * * * /usr/bin/other #gecoosac\n' >> "$CRONTAB"

configure_log_cleanup 0 0 weekly
assert_eq 1 "$CRON_RELOADS" 'changed crontab reload count'
! grep -q '#axonhub' "$CRONTAB" || fail 'disabled cleanup removes AxonHub rule'
grep -q '#gecoosac' "$CRONTAB" || fail 'other plugin rule is retained'
assert_eq 600 "$(stat -c %a "$CRONTAB")" 'crontab permissions'

configure_log_cleanup 0 0 weekly
assert_eq 1 "$CRON_RELOADS" 'unchanged crontab skips reload'

configure_log_cleanup 1 0 weekly
grep -q '^0 3 \* \* 0 /usr/libexec/axonhub-log-cleanup #axonhub$' "$CRONTAB" || fail 'weekly rule'
assert_eq 2 "$CRON_RELOADS" 'enabled cleanup reload count'

for _ in $(seq 1 30); do
	(configure_log_cleanup 1 0 weekly) &
done
wait
assert_eq 1 "$(grep -c '#axonhub' "$CRONTAB")" 'concurrent updates retain one AxonHub rule'
assert_eq 1 "$(grep -c '#gecoosac' "$CRONTAB")" 'concurrent updates retain other rule'

configure_log_cleanup 1 1 weekly
! grep -q '#axonhub' "$CRONTAB" || fail 'system logging disables file cleanup rule'

validate_data_dir '/mnt/disk/axonhub' || fail 'valid data directory rejected'
! validate_data_dir '/mnt/My Disk/axonhub' || fail 'unsupported spaced directory accepted'
! validate_data_dir '/tmp/axonhub' || fail 'volatile directory accepted'

grep -q '^CRON_LOCK=/var/lock/root-crontab$' "$INIT" || fail 'root crontab lock path'
printf 'simulate-init: all assertions passed\n'
