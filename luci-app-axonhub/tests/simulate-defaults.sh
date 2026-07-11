#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULTS="$PACKAGE_DIR/root/etc/uci-defaults/luci-axonhub"

declare -A STATE=(
	[axonhub.main.data_dir]='/mnt/large/axonhub'
	[axonhub.main.port]='34567'
	[axonhub.main.config_version]='4'
	[axonhub.main.listen_addr]='127.0.0.1'
	[axonhub.main.log_to_syslog]='0'
	[axonhub.main.log_cleanup_schedule]='weekly'
)

uci() {
	[ "${1:-}" = '-q' ] && shift
	local action="${1:-}"
	shift || true
	local expression key value

	case "$action" in
	get)
		key="${1:-}"
		[ -n "${STATE[$key]+x}" ] || return 1
		echo "${STATE[$key]}"
		;;
	set)
		expression="${1:-}"
		key="${expression%%=*}"
		value="${expression#*=}"
		STATE[$key]="$value"
		;;
	delete)
		unset 'STATE[$1]'
		;;
	commit)
		return 0
		;;
	batch)
		while IFS= read -r _; do :; done
		;;
	*)
		return 1
		;;
	esac
}

set +e
source <(sed \
	-e 's|^rm -rf /tmp/luci-\*$|:|' \
	-e 's|^exit 0$|:|' \
	"$DEFAULTS")
result=$?
set -e
[ "$result" -eq 0 ]

[ "${STATE[axonhub.main.config_version]}" = '5' ]
[ -z "${STATE[axonhub.main.listen_addr]+x}" ]
[ "${STATE[axonhub.main.data_dir]}" = '/mnt/large/axonhub' ]
[ "${STATE[axonhub.main.port]}" = '34567' ]
[ "${STATE[axonhub.main.log_cleanup_schedule]}" = 'daily' ]

echo 'simulate-defaults: all assertions passed'
