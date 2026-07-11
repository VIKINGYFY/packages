#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$PACKAGE_DIR/root/usr/libexec/gecoosac-log-runner"
TEST_ROOT="$(mktemp -d "$HOME/.gecoosac-runner.XXXXXX")"
LOG_FILE="$TEST_ROOT/logs/gecoosac.log"
PRODUCER="$TEST_ROOT/producer"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/logs"

cat > "$PRODUCER" <<-'EOF'
	#!/bin/sh
	dd if=/dev/zero bs=1048576 count=21 status=none
	sleep 2
	printf 'tail-entry\n'
EOF
chmod 755 "$PRODUCER"

GECOOSAC_LOG_MAX_SIZE_MB=10 GECOOSAC_LOG_CHECK_INTERVAL=1 "$RUNNER" "$LOG_FILE" "$PRODUCER"
[ "$(wc -c < "$LOG_FILE")" -lt 1048576 ]
grep -aq 'tail-entry' "$LOG_FILE"

for size in 10 20 30 40 50; do
	truncate -s "$((size * 1048576 + 1))" "$LOG_FILE"
	GECOOSAC_LOG_MAX_SIZE_MB="$size" "$RUNNER" "$LOG_FILE" /bin/true
	[ "$(wc -c < "$LOG_FILE")" -eq 0 ]
done

printf 'simulate-log-runner: all assertions passed\n'
