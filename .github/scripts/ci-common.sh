#!/usr/bin/env bash

CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="${REPO_ROOT:-$(cd -- "$CI_SCRIPT_DIR/../.." && pwd)}"

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

	sed -n "s/^${variable}:=//p" "$CI_REPO_ROOT/$package_dir/Makefile" |
		head -n1
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

ci_sync_branch() {
	local branch="$1"
	local target

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
	local local_head remote_head
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
		return 0
	fi
	git diff --cached --check

	git config user.name 'github-actions[bot]'
	git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
	git commit -m "$message"
	git push origin "HEAD:$branch"
}

ci_tag_matches_prefix() {
	local tag="$1"
	shift
	local prefix

	for prefix in "$@"; do
		[[ "$tag" == "$prefix"* ]] && return 0
	done
	return 1
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

ci_prune_releases() {
	local keep_tag="$1"
	shift
	local tag

	: "${GH_TOKEN:?GH_TOKEN is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

	while IFS= read -r tag; do
		[[ -n "$tag" && "$tag" != "$keep_tag" ]] || continue
		ci_tag_matches_prefix "$tag" "$@" || continue
		ci_delete_release_and_tag "$tag"
	done < <(
		gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 \
			--json tagName --jq '.[].tagName'
	)

	while IFS= read -r tag; do
		[[ -n "$tag" && "$tag" != "$keep_tag" ]] || continue
		ci_tag_matches_prefix "$tag" "$@" || continue
		ci_delete_release_and_tag "$tag"
	done < <(
		git ls-remote --tags "https://github.com/$GITHUB_REPOSITORY.git" |
			awk -F 'refs/tags/' 'NF == 2 && $2 !~ /\^\{\}$/ { print $2 }'
	)
}
