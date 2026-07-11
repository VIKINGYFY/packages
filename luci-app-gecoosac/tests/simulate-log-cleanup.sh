#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="$PACKAGE_DIR/root/usr/libexec/gecoosac-log-cleanup"
TEST_ROOT="$(mktemp -d "$HOME/.gecoosac-log.XXXXXX")"
LOG_DIR="$TEST_ROOT/db/logs"
LOG_FILE="$LOG_DIR/gecoosac.log"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$LOG_DIR"

run_cleanup() {
	DB_DIR="$TEST_ROOT/db" bash <(sed \
		-e 's|^\. /lib/functions.sh$|config_load() { :; }; config_get() { printf -v "$1" "%s" "$DB_DIR"; }|' \
		"$CLEANUP") "$@"
}

printf 'calendar\n' > "$LOG_FILE"
run_cleanup
[ "$(wc -c < "$LOG_FILE")" -eq 0 ]

printf 'simulate-log-cleanup: all assertions passed\n'
