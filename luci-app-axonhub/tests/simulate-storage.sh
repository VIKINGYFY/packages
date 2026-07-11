#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$PACKAGE_DIR/root/usr/libexec/axonhub-find-storage"
TEST_ROOT="$(mktemp -d "$HOME/.axonhub-storage.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/large" "$TEST_ROOT/small" "$TEST_ROOT/bad:path"
cat > "$TEST_ROOT/mounts" <<-EOF
	dev1 $TEST_ROOT/small ext4 rw 0 0
	dev2 $TEST_ROOT/large ext4 rw 0 0
	dev3 $TEST_ROOT/bad:path ext4 rw 0 0
	dev4 /tmp ext4 rw 0 0
EOF

df() {
	case "$2" in
		*large) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ndev 2000000 1 1500000 1%% %s\n' "$2" ;;
		*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ndev 1000000 1 800000 1%% %s\n' "$2" ;;
	esac
}
export -f df

result="$(sed "s|done < /proc/mounts|done < '$TEST_ROOT/mounts'|" "$HELPER" | bash)"
[ "$result" = "$TEST_ROOT/large/axonhub" ]

printf 'simulate-storage: all assertions passed\n'
