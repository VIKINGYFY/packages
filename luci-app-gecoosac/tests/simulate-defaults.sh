#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULTS="$PACKAGE_DIR/root/etc/uci-defaults/luci-gecoosac"

declare -A STATE=(
	[gecoosac.config.port]='34568'
	[gecoosac.config.config_version]='1'
	[gecoosac.config.log]='1'
	[gecoosac.config.log_cleanup_schedule]='weekly'
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
		printf '%s\n' "${STATE[$key]}"
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
	*) return 1 ;;
	esac
}

set +e
source <(sed -e 's|^exit 0$|:|' "$DEFAULTS")
result=$?
set -e
[ "$result" -eq 0 ]

[ "${STATE[gecoosac.config.config_version]}" = '2' ]
[ "${STATE[gecoosac.config.log]}" = '0' ]
[ "${STATE[gecoosac.config.log_max_size]}" = '20' ]
[ "${STATE[gecoosac.config.log_cleanup_schedule]}" = 'daily' ]
[ "${STATE[gecoosac.config.port]}" = '34568' ]

printf 'simulate-defaults: all assertions passed\n'
