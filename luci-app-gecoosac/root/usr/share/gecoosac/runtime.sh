#!/bin/sh

normalize_directory() {
	local path="$1"

	while [ "$path" != "${path%/}" ]; do
		path="${path%/}"
	done
	[ -n "$path" ] || path='/'
	printf '%s\n' "$path"
}

validate_directory() {
	case "$1" in
		/*) ;;
		*) return 1 ;;
	esac

	case "$1" in
		/|*[!A-Za-z0-9_./-]*) return 1 ;;
	esac
	case "$1/" in
		*/../*) return 1 ;;
	esac

	return 0
}

validate_db_directory() {
	validate_directory "$1" || return 1

	case "$1" in
		/tmp|/tmp/*|/var|/var/*|/rom|/rom/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
			return 1
			;;
	esac

	return 0
}
