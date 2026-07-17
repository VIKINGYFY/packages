#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

EVENT_NAME="${1:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
BEFORE_SHA="${2:-}"
REQUESTED_PACKAGES="${3:-}"

mapfile -t all_packages < <(ci_discover_packages)
selected_packages=()

select_all() {
	selected_packages=("${all_packages[@]}")
}

if [[ "$EVENT_NAME" == workflow_dispatch ]]; then
	if [[ -n "$REQUESTED_PACKAGES" ]]; then
		IFS=',' read -ra requested <<< "$REQUESTED_PACKAGES"
		for package in "${requested[@]}"; do
			package="${package//[[:space:]]/}"
			[[ -n "$package" ]] || continue
			if ! printf '%s\n' "${all_packages[@]}" | grep -Fqx "$package"; then
				printf '未知插件目录：%s\n' "$package" >&2
				exit 1
			fi
			selected_packages+=("$package")
		done
	else
		select_all
	fi
else
	if [[ -z "$BEFORE_SHA" ]] || [[ "$BEFORE_SHA" =~ ^0+$ ]]; then
		mapfile -t changed_files < <(git show --format= --name-only "$GITHUB_SHA")
	else
		mapfile -t changed_files < <(git diff --name-only "$BEFORE_SHA" "$GITHUB_SHA")
	fi

	removed_package=false
	if [[ -n "$BEFORE_SHA" ]] && [[ ! "$BEFORE_SHA" =~ ^0+$ ]]; then
		mapfile -t old_packages < <(
			git ls-tree -r --name-only "$BEFORE_SHA" |
				awk -F / 'NF == 2 && $2 == "Makefile" && $1 !~ /^\./ { print $1 }' |
				sort -u
		)
		for package in "${old_packages[@]}"; do
			if ! printf '%s\n' "${all_packages[@]}" | grep -Fqx "$package"; then
				removed_package=true
				break
			fi
		done
	fi

	if [[ "$removed_package" == true ]]; then
		select_all
	else
		for package in "${all_packages[@]}"; do
			package_changed=false
			only_nonbuild_files=true
			for path in "${changed_files[@]}"; do
				[[ "$path" == "$package/"* ]] || continue
				package_changed=true
				case "$path" in
					"$package/po/"*|"$package/README"|"$package/README.md") ;;
					*) only_nonbuild_files=false ;;
				esac
			done
			if [[ "$package_changed" == true && "$only_nonbuild_files" == false ]]; then
				selected_packages+=("$package")
			fi
		done
	fi
fi

if (( ${#selected_packages[@]} > 0 )); then
	mapfile -t selected_packages < <(
		printf '%s\n' "${selected_packages[@]}" | awk 'NF && !seen[$0]++' | sort
	)
	packages_csv="$(ci_join_csv "${selected_packages[@]}")"
	packages_display="$(ci_format_csv "$packages_csv")"
	changed=true
else
	packages_csv=''
	packages_display=''
	changed=false
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "changed=$changed"
		echo "packages=$packages_csv"
		echo "packages_display=$packages_display"
	} >> "$GITHUB_OUTPUT"
else
	printf 'changed=%s\npackages=%s\npackages_display=%s\n' \
		"$changed" "$packages_csv" "$packages_display"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	if [[ "$changed" == true ]]; then
		printf '### APK 插件：%s\n' "$packages_display" >> "$GITHUB_STEP_SUMMARY"
	else
		echo '未检测到需要编译的插件；纯翻译或说明变更不触发编译。' \
			>> "$GITHUB_STEP_SUMMARY"
	fi
fi
