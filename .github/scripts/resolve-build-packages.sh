#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

EVENT_NAME="${1:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
BEFORE_SHA="${2:-}"
REQUESTED_PACKAGES="${3:-}"
SOURCE_SHA="${4:-${SOURCE_SHA:-${GITHUB_SHA:-}}}"

ci_require_commit_sha "$SOURCE_SHA"
git -C "$CI_REPO_ROOT" cat-file -e "$SOURCE_SHA^{commit}"

mapfile -t all_packages < <(ci_discover_packages)
selected_packages=()

select_all() {
	selected_packages=("${all_packages[@]}")
}

# 可复用工作流继承调用方的事件名，显式软件包列表必须优先于事件类型。
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
elif [[ "$EVENT_NAME" == workflow_dispatch || "$EVENT_NAME" == workflow_call ]]; then
	select_all
else
	if [[ -z "$BEFORE_SHA" ]] || [[ "$BEFORE_SHA" =~ ^0+$ ]]; then
		mapfile -t changed_files < <(git show --format= --name-only "$SOURCE_SHA")
	else
		mapfile -t changed_files < <(git diff --name-only "$BEFORE_SHA" "$SOURCE_SHA")
	fi

	shared_build_changed=false
	for path in "${changed_files[@]}"; do
		case "$path" in
			.github/workflows/Build-APK-Packages.yml|\
			.github/scripts/build-apk-packages.sh|\
			.github/scripts/ci-common.sh|\
			.github/scripts/fix-package-permissions.sh|\
			.github/scripts/resolve-build-packages.sh)
				shared_build_changed=true
				break
				;;
		esac
	done

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

	if [[ "$shared_build_changed" == true || "$removed_package" == true ]]; then
		select_all
	else
		for package in "${all_packages[@]}"; do
			package_changed=false
			only_nonbuild_files=true
			for path in "${changed_files[@]}"; do
				[[ "$path" == "$package/"* ]] || continue
				package_changed=true
				case "$path" in
					"$package/README"|"$package/README.md") ;;
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
