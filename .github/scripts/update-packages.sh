#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

cd "$CI_REPO_ROOT"

PACKAGE_BRANCH="${PACKAGE_BRANCH:-${GITHUB_REF_NAME:-main}}"
MANIFEST_DIR="${UPDATE_MANIFEST_DIR:-${RUNNER_TEMP:-/tmp}/update-manifest}"
COMMITS_FILE="$MANIFEST_DIR/commits.tsv"
STAGE="${1:-}"

mkdir -p "$MANIFEST_DIR"
[[ -n "$STAGE" ]] || {
	printf '必须指定更新阶段。\n' >&2
	exit 2
}
[[ -f "$COMMITS_FILE" ]] || : > "$COMMITS_FILE"
ci_sync_branch "$PACKAGE_BRANCH"

record_commit() {
	local before_sha="$1"
	local after_sha="$2"
	local changed_paths packages

	changed_paths="$(git diff --name-only "$before_sha" "$after_sha")"
	packages="$(printf '%s\n' "$changed_paths" | ci_packages_from_paths | paste -sd, -)"
	printf '%s\t%s\t%s\n' "$after_sha" "$packages" "$before_sha" >> "$COMMITS_FILE"
}

commit_update() {
	local message="$1"
	shift
	local before_sha after_sha

	before_sha="$(git rev-parse HEAD)"
	ci_commit_and_push "$PACKAGE_BRANCH" "$message" "$@"
	after_sha="$(git rev-parse HEAD)"
	if [[ "$before_sha" != "$after_sha" ]]; then
		record_commit "$before_sha" "$after_sha"
	fi
}

update_sing_box() {
	local makefile='sing-box/Makefile'
	local upstream_tag upstream_version current_version archive source_dir source_hash

	upstream_tag="$(gh api 'repos/SagerNet/sing-box/releases?per_page=30' \
		--jq '[.[] | select(.draft == false)][0].tag_name')"
	[[ "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]
	upstream_version="${upstream_tag#v}"
	current_version="$(sed -n 's/^PKG_UPSTREAM_VERSION:=//p' "$makefile")"
	if [[ "$current_version" == "$upstream_version" ]]; then
		echo "Sing-Box 已是最新版本：$upstream_version"
		return 0
	fi

	archive="$RUNNER_TEMP/sing-box.tar.gz"
	source_dir="$RUNNER_TEMP/sing-box-source"
	curl -fL --retry 3 \
		"https://codeload.github.com/SagerNet/sing-box/tar.gz/$upstream_tag" \
		-o "$archive"
	tar -tzf "$archive" >/dev/null
	rm -rf "$source_dir"
	mkdir -p "$source_dir"
	tar -xzf "$archive" --strip-components=1 -C "$source_dir"
test -s "$source_dir/go.mod"

	for patch_file in sing-box/patches/*.patch; do
		[[ -f "$patch_file" ]] || continue
		patch --batch --fuzz=0 -p1 -d "$source_dir" < "$patch_file"
	done

	source_hash="$(sha256sum "$archive" | cut -d' ' -f1)"
	sed -i \
		-e "s/^PKG_UPSTREAM_VERSION:=.*/PKG_UPSTREAM_VERSION:=$upstream_version/" \
		-e 's/^PKG_RELEASE:=.*/PKG_RELEASE:=1/' \
		-e "s/^PKG_HASH:=.*/PKG_HASH:=$source_hash/" \
		"$makefile"

	grep -Fx "PKG_UPSTREAM_VERSION:=$upstream_version" "$makefile"
	grep -Fx 'PKG_RELEASE:=1' "$makefile"
	grep -Fx "PKG_HASH:=$source_hash" "$makefile"
	git diff --check
	commit_update "chore: 更新 Sing-Box 至 ${upstream_version}-r1" "$makefile"
}

update_axonhub() {
	local makefile='axonhub/Makefile'
	local upstream_commit current_commit archive source_dir source_hash

	upstream_commit="$(git ls-remote \
		https://github.com/looplj/axonhub.git refs/heads/unstable | cut -f1)"
	[[ "$upstream_commit" =~ ^[0-9a-f]{40}$ ]]
	current_commit="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$makefile")"
	if [[ "$current_commit" == "$upstream_commit" ]]; then
		echo "AxonHub 上游无更新：$upstream_commit"
		return 0
	fi

	archive="$RUNNER_TEMP/axonhub.tar.gz"
	source_dir="$RUNNER_TEMP/axonhub-source"
	curl -fL --retry 3 \
		"https://codeload.github.com/looplj/axonhub/tar.gz/$upstream_commit" \
		-o "$archive"
	tar -tzf "$archive" >/dev/null
	rm -rf "$source_dir"
	mkdir -p "$source_dir"
	tar -xzf "$archive" --strip-components=1 -C "$source_dir"
	test -s "$source_dir/go.mod"
	test -s "$source_dir/frontend/pnpm-lock.yaml"

	for patch_file in axonhub/patches/*.patch; do
		[[ -f "$patch_file" ]] || continue
		patch --batch --fuzz=0 -p1 -d "$source_dir" < "$patch_file"
	done

	source_hash="$(sha256sum "$archive" | cut -d' ' -f1)"
	package_version="$(TZ=Asia/Shanghai date +%Y%m%d)"
	current_version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile")"
	current_release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile")"
	release=1
	if [[ "$current_version" == "$package_version" ]]; then
		[[ "$current_release" =~ ^[0-9]+$ ]]
		release=$((current_release + 1))
	fi

	sed -i \
		-e "s/^PKG_VERSION:=.*/PKG_VERSION:=$package_version/" \
		-e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$release/" \
		-e "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$upstream_commit/" \
		-e "s/^PKG_HASH:=.*/PKG_HASH:=$source_hash/" \
		"$makefile"
	grep -Fx "PKG_VERSION:=$package_version" "$makefile"
	grep -Fx "PKG_RELEASE:=$release" "$makefile"
	grep -Fx "PKG_SOURCE_VERSION:=$upstream_commit" "$makefile"
	grep -Fx "PKG_HASH:=$source_hash" "$makefile"
	git diff --check
	commit_update "chore: 更新 AxonHub 至 ${package_version}-r${release}" "$makefile"
}

update_homeproxy() {
	.github/scripts/update-homeproxy-geodata.sh
	git diff --check
	commit_update \
		'chore: 更新 HomeProxy 数据' \
		luci-app-homeproxy/root/etc/homeproxy/resources \
		luci-app-homeproxy/root/etc/homeproxy/dashboard
}

update_miniupnp() {
	local makefile='miniupnpd/Makefile'
	local upstream_commit current_commit archive source_dir source_hash

	upstream_commit="$(git ls-remote \
		https://github.com/miniupnp/miniupnp.git refs/heads/master | cut -f1)"
	[[ "$upstream_commit" =~ ^[0-9a-f]{40}$ ]]
	current_commit="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$makefile")"
	if [[ "$current_commit" == "$upstream_commit" ]]; then
		echo "MiniUPnP 上游无更新：$upstream_commit"
		return 0
	fi

	archive="$RUNNER_TEMP/miniupnpd.tar.gz"
	source_dir="$RUNNER_TEMP/miniupnpd-source"
	curl -fL --retry 3 \
		"https://codeload.github.com/miniupnp/miniupnp/tar.gz/$upstream_commit" \
		-o "$archive"
	tar -tzf "$archive" >/dev/null
	rm -rf "$source_dir"
	mkdir -p "$source_dir"
	tar -xzf "$archive" --strip-components=1 -C "$source_dir"
	test -x "$source_dir/miniupnpd/configure"
	test -s "$source_dir/miniupnpd/upnpredirect.c"
	test -s "$source_dir/miniupnpd/miniupnpd.c"

	for patch_file in miniupnpd/patches/*.patch; do
		[[ -f "$patch_file" ]] || continue
		patch --batch --forward --fuzz=0 -p1 -d "$source_dir" < "$patch_file"
	done

	source_hash="$(sha256sum "$archive" | cut -d' ' -f1)"
	package_version="$(TZ=Asia/Shanghai date +%Y%m%d)"
	current_version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile")"
	current_release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile")"
	release=1
	if [[ "$current_version" == "$package_version" ]]; then
		[[ "$current_release" =~ ^[0-9]+$ ]]
		release=$((current_release + 1))
	fi

	sed -i \
		-e "s/^PKG_VERSION:=.*/PKG_VERSION:=$package_version/" \
		-e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$release/" \
		-e "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$upstream_commit/" \
		-e "s/^PKG_HASH:=.*/PKG_HASH:=$source_hash/" \
		"$makefile"
	grep -Fx "PKG_VERSION:=$package_version" "$makefile"
	grep -Fx "PKG_RELEASE:=$release" "$makefile"
	grep -Fx "PKG_SOURCE_VERSION:=$upstream_commit" "$makefile"
	grep -Fx "PKG_HASH:=$source_hash" "$makefile"
	git diff --check
	commit_update "chore: 更新 MiniUPnP 至 ${package_version}-r${release}" "$makefile"
}

update_translation() {
	local temp_dir package_dir package_changed makefile
	local package_version current_version current_release release path

	.github/scripts/maintain-repository.sh
	.github/scripts/rescan-translations.sh
	temp_dir="$(mktemp -d)"
	ci_discover_packages > "$temp_dir/packages"
	while IFS= read -r package_dir; do
		[[ "$package_dir" == luci-app-* ]] || continue
		git diff --name-only -- "$package_dir" > "$temp_dir/changed-files"
		package_changed=false
		while IFS= read -r path; do
			case "$path" in
				"$package_dir"/htdocs/*|"$package_dir"/luasrc/*|"$package_dir"/root/*|"$package_dir"/po/*.po)
					package_changed=true
					break
					;;
			esac
		done < "$temp_dir/changed-files"
		[[ "$package_changed" == true ]] || continue

		makefile="$package_dir/Makefile"
		package_version="$(TZ=Asia/Shanghai date +%Y%m%d)"
		current_version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile")"
		current_release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile")"
		release=1
		if [[ "$current_version" == "$package_version" ]]; then
			[[ "$current_release" =~ ^[0-9]+$ ]]
			release=$((current_release + 1))
		fi
		sed -i \
			-e "s/^PKG_VERSION:=.*/PKG_VERSION:=$package_version/" \
			-e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$release/" \
			"$makefile"
		grep -Fx "PKG_VERSION:=$package_version" "$makefile"
		grep -Fx "PKG_RELEASE:=$release" "$makefile"
	done < "$temp_dir/packages"
	.github/scripts/generate-readme.sh
	git diff --check
	commit_update 'chore: 维护插件说明、翻译与权限' .
	rm -rf -- "$temp_dir"
}

case "$STAGE" in
	singbox) update_sing_box ;;
	axonhub) update_axonhub ;;
	homeproxy) update_homeproxy ;;
	miniupnp) update_miniupnp ;;
	translation) update_translation ;;
	*)
		printf '未知更新阶段：%s\n' "$STAGE" >&2
		exit 2
		;;
esac
