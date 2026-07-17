#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

cd "$CI_REPO_ROOT"
mapfile -t package_dirs < <(ci_discover_packages)
metadata_file="$CI_REPO_ROOT/.github/package-sources.tsv"

for package_dir in "${package_dirs[@]}"; do
	find "$package_dir" -maxdepth 1 -type f \
		\( -name README -o -name README.md \) -print -delete
done

if [[ -f "$metadata_file" ]]; then
	metadata_temp="$(mktemp)"
	trap 'rm -f -- "$metadata_temp"' EXIT
	while IFS=$'\t' read -r package_dir source_url; do
		[[ -n "$package_dir" && -n "$source_url" ]] || continue
		[[ -f "$CI_REPO_ROOT/$package_dir/Makefile" ]] || continue
		printf '%s\t%s\n' "$package_dir" "$source_url"
	done < "$metadata_file" | sort -u > "$metadata_temp"
	mv -f -- "$metadata_temp" "$metadata_file"
	trap - EXIT
fi

"$SCRIPT_DIR/fix-package-permissions.sh" "${package_dirs[@]}"
"$SCRIPT_DIR/generate-readme.sh"
