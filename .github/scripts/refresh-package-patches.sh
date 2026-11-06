#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
export LC_ALL=C

if (( $# != 3 )); then
	printf 'Usage: %s <upstream-source-dir> <patch-dir> <output-dir>\n' "$0" >&2
	exit 2
fi

source_dir="$(realpath "$1")"
patch_dir="$(realpath "$2")"
output_dir="$(realpath "$3")"

[[ -d "$source_dir" && -d "$patch_dir" && -d "$output_dir" ]]
[[ ! -e "$source_dir/.pc" && "$patch_dir" != "$output_dir" ]]
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]

cp -a "$patch_dir/." "$output_dir/"
if [[ -f "$output_dir/series" ]]; then
	mapfile -t patches < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$output_dir/series")
else
	patches=("$output_dir/"*.patch)
	for patch_file in "${patches[@]}"; do
		printf '%s\n' "${patch_file##*/}" >> "$output_dir/series"
	done
fi
(( ${#patches[@]} > 0 )) || exit 0

export QUILT_PATCHES="$output_dir"
export QUILT_SERIES=series
export QUILT_PC=.pc

cd "$source_dir"
for patch_file in "${patches[@]}"; do
	printf '检查并刷新补丁：%s\n' "${patch_file##*/}"
	quilt --quiltrc=- push --fuzz=0
	# Match OpenWrt include/quilt.mk's package/refresh recipe.
	# https://github.com/openwrt/openwrt/blob/main/include/quilt.mk
	QUILT_DIFF_OPTS="-p" quilt --quiltrc=- refresh -p ab --no-index --no-timestamps
done

# Replay the complete refreshed stack before the updater copies or commits it.
quilt --quiltrc=- pop -a
quilt --quiltrc=- push -a --fuzz=0
