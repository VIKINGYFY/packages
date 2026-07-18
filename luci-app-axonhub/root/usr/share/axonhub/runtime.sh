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
		*[!A-Za-z0-9_./-]*) return 1 ;;
	esac
	case "$1/" in
		*/../*) return 1 ;;
	esac

	return 0
}

validate_data_dir() {
	validate_directory "$1" || return 1

	case "$1" in
		/|/tmp|/tmp/*|/var|/var/*|/rom|/rom/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
			return 1
			;;
	esac

	return 0
}

external_mount_ready() {
	case "$1" in
		/mnt/*|/media/*)
			awk -v path="$1" '
				$2 != "/" && (path == $2 || index(path, $2 "/") == 1) { found = 1 }
				END { exit(found ? 0 : 1) }
			' /proc/mounts
			return $?
			;;
	esac

	return 0
}
