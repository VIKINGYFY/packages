#!/usr/bin/env bash

CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="${REPO_ROOT:-$(cd -- "$CI_SCRIPT_DIR/../.." && pwd)}"

ci_write_output() {
	local name="$1"
	local value="$2"

	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}

ci_require_commit_sha() {
	local sha="$1"

	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
		printf '无效的 Git 提交 SHA：%s\n' "$sha" >&2
		return 1
	}
}

ci_discover_packages() {
	find "$CI_REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name Makefile \
		-printf '%h\n' |
		sed "s#^$CI_REPO_ROOT/##" |
		awk -F / '$1 !~ /^\./' |
		sort -u
}

ci_make_value() {
	local package_dir="$1"
	local variable="$2"
	local makefile="$CI_REPO_ROOT/$package_dir/Makefile"
	local value

	value="$(sed -n "s/^${variable}:=//p" "$makefile" | head -n1)"
	if [[ "$variable" == PKG_VERSION && "$value" == *"\$("* ]]; then
		# Evaluate version expressions without loading the OpenWrt build includes.
		{
			awk '/^PKG_(NAME|UPSTREAM_VERSION|VERSION|RELEASE):=/' "$makefile"
			printf "\nci-print-version:\n\t@printf '%%s\\\\n' '\$(PKG_VERSION)'\n"
		} | make --no-print-directory -rRs -f - ci-print-version
	else
		printf '%s\n' "$value"
	fi
}

ci_package_name() {
	local package_dir="$1"
	local name

	name="$(ci_make_value "$package_dir" PKG_NAME)"
	[[ -n "$name" ]] || {
		printf 'PKG_NAME not found in %s/Makefile\n' "$package_dir" >&2
		return 1
	}
	printf '%s\n' "$name"
}

ci_package_names() {
	local package_dir="$1"
	local manifest="$CI_REPO_ROOT/$package_dir/APK-PACKAGES"
	local name
	local -a names=()
	local -A seen=()

	if [[ ! -f "$manifest" ]]; then
		ci_package_name "$package_dir"
		return
	fi

	while IFS= read -r name || [[ -n "$name" ]]; do
		[[ -n "$name" ]] || continue
		[[ "$name" == \#* ]] && continue
		[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.+-]*$ ]] || {
			printf 'Invalid package name in %s: %s\n' "$manifest" "$name" >&2
			return 1
		}
		[[ -z "${seen[$name]:-}" ]] || {
			printf 'Duplicate package name in %s: %s\n' "$manifest" "$name" >&2
			return 1
		}
		seen["$name"]=1
		names+=("$name")
	done < "$manifest"

	(( ${#seen[@]} > 0 )) || {
		printf 'No package names in %s\n' "$manifest" >&2
		return 1
	}
	printf '%s\n' "${names[@]}"
}

ci_package_version() {
	local package_dir="$1"
	local version release

	version="$(ci_make_value "$package_dir" PKG_VERSION)"
	release="$(ci_make_value "$package_dir" PKG_RELEASE)"
	if [[ -z "$version" ]]; then
		printf '自动\n'
	elif [[ "$release" =~ ^[0-9]+$ ]]; then
		printf '%s-r%s\n' "$version" "$release"
	else
		printf '%s\n' "$version"
	fi
}

ci_join_csv() {
	local IFS=,
	printf '%s\n' "$*"
}

ci_format_csv() {
	awk -v value="$1" 'BEGIN {
		n = split(value, fields, /,[[:space:]]*/)
		for (i = 1; i <= n; i++) {
			if (fields[i] == "") continue
			printf "%s%s", count++ ? ", " : "", fields[i]
		}
		print ""
	}'
}

ci_packages_from_paths() {
	local path package
	declare -A seen=()

	while IFS= read -r path; do
		[[ "$path" == */* ]] || continue
		package="${path%%/*}"
		[[ -f "$CI_REPO_ROOT/$package/Makefile" ]] || continue
		[[ -z "${seen[$package]:-}" ]] || continue
		seen["$package"]=1
		printf '%s\n' "$package"
	done | sort
}

ci_sync_branch() {
	local branch="$1"
	local target

	[[ "${GITHUB_ACTIONS:-}" == true ]] || {
		printf 'ci_sync_branch 仅允许在 GitHub Actions 临时工作区运行。\n' >&2
		return 1
	}

	cd "$CI_REPO_ROOT" || return 1
	git fetch origin "$branch"
	target="$(git rev-parse "origin/$branch")"
	printf '同步仓库：%s，分支：%s，目标提交：%s\n' \
		"$CI_REPO_ROOT" "$branch" "$target"
	git reset --hard "origin/$branch"
}

ci_commit_and_push() {
	local branch="$1"
	local message="$2"
	local base_sha commit_sha local_head remote_head pushed_head
	local packages_csv packages_display
	local changed_paths package_paths path
	local removed_package=false
	local -a changed_files package_dirs
	shift 2

	[[ "$message" =~ ^[a-z]+:\ .+ ]] || {
		printf '提交信息格式无效：%s\n' "$message" >&2
		return 1
	}
	(( $# > 0 )) || {
		printf '未提供提交路径。\n' >&2
		return 1
	}

	cd "$CI_REPO_ROOT" || return 1
	local_head="$(git rev-parse HEAD)"
	base_sha="$local_head"
	git fetch origin "$branch"
	remote_head="$(git rev-parse "origin/$branch")"
	if [[ "$local_head" != "$remote_head" ]]; then
		printf '远端分支已更新，为避免提交冲突，本次任务停止：%s -> %s\n' \
			"$local_head" "$remote_head" >&2
		return 75
	fi

	git add -- "$@"
	if git diff --cached --quiet; then
		printf '没有需要提交的变更。\n'
		ci_write_output changed false
		ci_write_output base_sha "$base_sha"
		ci_write_output commit_sha "$base_sha"
		ci_write_output packages ''
		ci_write_output packages_display ''
		return 0
	fi
	git diff --cached --check
	changed_paths="$(git diff --cached --name-only)" || return 1
	mapfile -t changed_files <<< "$changed_paths"
	package_paths="$(printf '%s\n' "${changed_files[@]}" | ci_packages_from_paths)" || return 1
	package_dirs=()
	if [[ -n "$package_paths" ]]; then
		mapfile -t package_dirs <<< "$package_paths"
	fi
	for path in "${changed_files[@]}"; do
		if [[ "$path" == */Makefile && "$path" != */*/* && \
			"${path%%/*}" != .* && ! -f "$CI_REPO_ROOT/$path" ]]; then
			removed_package=true
			break
		fi
	done
	if [[ "$removed_package" == true ]]; then
		package_paths="$(ci_discover_packages)" || return 1
		package_dirs=()
		if [[ -n "$package_paths" ]]; then
			mapfile -t package_dirs <<< "$package_paths"
		fi
	fi
	if (( ${#package_dirs[@]} > 0 )); then
		packages_csv="$(ci_join_csv "${package_dirs[@]}")"
		packages_display="$(ci_format_csv "$packages_csv")"
	else
		packages_csv=''
		packages_display=''
	fi

	git config user.name 'github-actions[bot]'
	git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
	git commit -m "$message"
	commit_sha="$(git rev-parse HEAD)"
	git push origin "HEAD:$branch"
	pushed_head="$(git ls-remote --heads origin "refs/heads/$branch" | cut -f1)"
	[[ "$pushed_head" == "$commit_sha" ]] || {
		printf '远端分支未指向刚推送的提交：%s != %s\n' \
			"$pushed_head" "$commit_sha" >&2
		return 1
	}

	ci_write_output changed true
	ci_write_output base_sha "$base_sha"
	ci_write_output commit_sha "$commit_sha"
	ci_write_output packages "$packages_csv"
	ci_write_output packages_display "$packages_display"
}

ci_delete_release_and_tag() {
	local tag="$1"

	: "${GH_TOKEN:?GH_TOKEN is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

	if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
		printf '删除过期 Release 和 Tag：%s\n' "$tag"
		gh release delete "$tag" --repo "$GITHUB_REPOSITORY" \
			--cleanup-tag --yes
	elif git ls-remote --exit-code --tags \
		"https://github.com/$GITHUB_REPOSITORY.git" "refs/tags/$tag" \
		>/dev/null 2>&1; then
		printf '删除孤立 Tag：%s\n' "$tag"
		gh api --method DELETE \
			"repos/$GITHUB_REPOSITORY/git/refs/tags/$tag"
	fi
}
