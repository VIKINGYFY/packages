#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$PACKAGE_DIR/root/etc/init.d/gecoosac"
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
source <(sed -e '1,4d' "$INIT")
CRON_FILE="$CRONTAB"
CRON_LOCK="$LOCKFILE"
CRON_RELOADS=0

reload_cron() {
	CRON_RELOADS=$((CRON_RELOADS + 1))
}

printf '1 1 * * * /usr/bin/unrelated #keep\n' > "$CRONTAB"
printf '0 3 * * 0 /usr/libexec/gecoosac-log-cleanup #gecoosac\n' >> "$CRONTAB"
printf '17 * * * * /usr/libexec/gecoosac-log-cleanup size #gecoosac-size\n' >> "$CRONTAB"
printf '2 2 * * * /usr/bin/other #axonhub\n' >> "$CRONTAB"

configure_log_cleanup 1 1 weekly
assert_eq 1 "$(grep -c '#gecoosac$' "$CRONTAB")" 'weekly cleanup rule'
assert_eq 0 "$(grep -c '#gecoosac-size$' "$CRONTAB" || true)" 'legacy hourly size rule is removed'
assert_eq 1 "$CRON_RELOADS" 'normalized rule order reloads cron once'
assert_eq 600 "$(stat -c %a "$CRONTAB")" 'crontab permissions'

configure_log_cleanup 1 1 weekly
assert_eq 1 "$CRON_RELOADS" 'unchanged rules skip cron reload'

configure_log_cleanup 1 1 disabled
assert_eq 0 "$(grep -c '#gecoosac$' "$CRONTAB" || true)" 'disabled calendar cleanup'
assert_eq 0 "$(grep -c '#gecoosac-size$' "$CRONTAB" || true)" 'size limit does not use cron'
assert_eq 2 "$CRON_RELOADS" 'changed rules reload cron'

for _ in $(seq 1 30); do
	(configure_log_cleanup 1 1 monthly) &
done
wait
assert_eq 1 "$(grep -c '#gecoosac$' "$CRONTAB")" 'concurrent updates retain one cleanup rule'
assert_eq 0 "$(grep -c '#gecoosac-size$' "$CRONTAB" || true)" 'concurrent updates do not add size cron'
assert_eq 1 "$(grep -c '#axonhub$' "$CRONTAB")" 'other plugin rule is retained'

configure_log_cleanup 0 0 disabled
assert_eq 0 "$(grep -c '#gecoosac' "$CRONTAB" || true)" 'stopping removes all Gecoos AC rules'

validate_directory '/mnt/firmware' || fail 'valid firmware directory rejected'
! validate_directory '/tmp/../etc' || fail 'parent directory accepted'
validate_db_directory '/etc/gecoosac' || fail 'valid database directory rejected'
! validate_db_directory '/tmp/gecoosac' || fail 'volatile database directory accepted'

grep -q '^CRON_LOCK=/var/lock/root-crontab$' "$INIT" || fail 'root crontab lock path'
[ "$(normalize_cleanup_schedule invalid)" = 'daily' ] || fail 'invalid schedule defaults to daily'
for size in 10 20 30 40 50; do
	[ "$(normalize_log_max_size "$size")" = "$size" ] || fail "valid log size $size rejected"
done
[ "$(normalize_log_max_size invalid)" = '20' ] || fail 'invalid log size defaults to 20'
printf 'simulate-init: all assertions passed\n'
