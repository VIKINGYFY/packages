#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

EVENT_NAME="${1:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
BEFORE_SHA="${2:-}"
REQUESTED_PACKAGES="${3:-}"
SOURCE_SHA="${4:-${SOURCE_SHA:-${GITHUB_SHA:-}}}"

case "$EVENT_NAME" in
	push|workflow_dispatch) ;;
	*)
		printf '不支持的编译触发事件：%s\n' "$EVENT_NAME" >&2
		exit 2
		;;
esac

ci_require_commit_sha "$SOURCE_SHA"
git -C "$CI_REPO_ROOT" cat-file -e "$SOURCE_SHA^{commit}"

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
ci_discover_packages > "$temp_dir/packages"
mapfile -t all_packages < "$temp_dir/packages"
selected_packages=()

select_all() {
	selected_packages=("${all_packages[@]}")
}

# 自动更新显式传入本次变更包；只有手动运行且留空时才编译全部。
if [[ -n "$REQUESTED_PACKAGES" ]]; then
	IFS=',' read -ra requested <<< "$REQUESTED_PACKAGES"
	for package in "${requested[@]}"; do
		package="${package//[[:space:]]/}"
		[[ -n "$package" ]] || continue
		if ! printf '%s\n' "${all_packages[@]}" | grep -Fqx "$package"; then
			printf '未知软件包目录：%s\n' "$package" >&2
			exit 1
		fi
		selected_packages+=("$package")
	done
elif [[ "$EVENT_NAME" == workflow_dispatch ]]; then
	select_all
else
	if [[ -z "$BEFORE_SHA" ]] || [[ "$BEFORE_SHA" =~ ^0+$ ]]; then
		git -C "$CI_REPO_ROOT" show --format= --name-only "$SOURCE_SHA" > "$temp_dir/changed-files"
	else
		ci_require_commit_sha "$BEFORE_SHA"
		git -C "$CI_REPO_ROOT" cat-file -e "$BEFORE_SHA^{commit}"
		git -C "$CI_REPO_ROOT" diff --name-only "$BEFORE_SHA" "$SOURCE_SHA" > "$temp_dir/changed-files"
	fi
	removed_package=false
	if [[ -n "$BEFORE_SHA" ]] && [[ ! "$BEFORE_SHA" =~ ^0+$ ]]; then
		git -C "$CI_REPO_ROOT" ls-tree -r --name-only "$BEFORE_SHA" |
			awk -F / 'NF == 2 && $2 == "Makefile" && $1 !~ /^\./ { print $1 }' |
			sort -u > "$temp_dir/old-packages"
		mapfile -t old_packages < "$temp_dir/old-packages"
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
		ci_packages_from_paths < "$temp_dir/changed-files" > "$temp_dir/changed-packages"
		mapfile -t selected_packages < "$temp_dir/changed-packages"
	fi
fi

if (( ${#selected_packages[@]} > 0 )); then
	printf '%s\n' "${selected_packages[@]}" | awk 'NF && !seen[$0]++' | sort > "$temp_dir/selected-packages"
	mapfile -t selected_packages < "$temp_dir/selected-packages"
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
		echo "source_sha=$SOURCE_SHA"
		echo "packages=$packages_csv"
		echo "packages_display=$packages_display"
	} >> "$GITHUB_OUTPUT"
else
	printf 'changed=%s\nsource_sha=%s\npackages=%s\npackages_display=%s\n' \
		"$changed" "$SOURCE_SHA" "$packages_csv" "$packages_display"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	if [[ "$changed" == true ]]; then
		printf '### APK 软件包：%s\n' "$packages_display" >> "$GITHUB_STEP_SUMMARY"
	else
		echo '未检测到需要编译的软件包；纯说明变更不触发编译。' \
			>> "$GITHUB_STEP_SUMMARY"
	fi
fi
