#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

cd "$CI_REPO_ROOT"
output="${1:-README.md}"
temp_file="$(mktemp)"
trap 'rm -f -- "$temp_file"' EXIT

repo_url="$(git remote get-url origin 2>/dev/null || true)"
repo_url="${repo_url%.git}"

source_override() {
	local package_dir="$1"
	local metadata="$CI_REPO_ROOT/.github/package-sources.tsv"

	[[ -f "$metadata" ]] || return 0
	awk -F '\t' -v package="$package_dir" '$1 == package { print $2; exit }' \
		"$metadata"
}

normalize_source_url() {
	local url="$1"

	url="${url%%\?*}"
	if [[ "$url" =~ ^https://codeload\.github\.com/([^/]+)/([^/]+)/ ]]; then
		printf 'https://github.com/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+) ]]; then
		printf 'https://github.com/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
	else
		printf '%s\n' "$url"
	fi
}

package_source_url() {
	local package_dir="$1"
	local makefile="$CI_REPO_ROOT/$package_dir/Makefile"
	local override source_url package_url go_pkg sibling dependency

	override="$(source_override "$package_dir")"
	[[ -z "$override" ]] || {
		printf '%s\n' "$override"
		return
	}

	if [[ "$package_dir" == luci-app-* ]]; then
		sibling="${package_dir#luci-app-}"
		if [[ -f "$CI_REPO_ROOT/$sibling/Makefile" ]]; then
			package_source_url "$sibling"
			return
		fi
		while IFS= read -r dependency; do
			if [[ -f "$CI_REPO_ROOT/$dependency/Makefile" ]]; then
				package_source_url "$dependency"
				return
			fi
		done < <(grep -oE '\+[A-Za-z0-9._+-]+' "$makefile" | sed 's/^+//' | sort -u)
	fi

	source_url="$(sed -n 's/^PKG_SOURCE_URL:=//p' "$makefile" | head -n1)"
	if [[ "$source_url" == http* ]]; then
		source_url="$(normalize_source_url "$source_url")"
		if [[ -n "$source_url" && "$source_url" != "$repo_url" ]]; then
			printf '%s\n' "$source_url"
			return
		fi
	fi

	package_url="$(sed -n 's/^[[:space:]]*URL:=//p' "$makefile" | head -n1)"
	if [[ "$package_url" == http* ]]; then
		printf '%s\n' "${package_url%/}"
		return
	fi

	go_pkg="$(ci_make_value "$package_dir" GO_PKG)"
	if [[ "$go_pkg" == github.com/*/* ]]; then
		printf 'https://%s\n' "$go_pkg"
		return
	fi

	printf '%s\n' "$repo_url"
}

source_label() {
	local url="$1"
	local label

	if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+) ]]; then
		label="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
	else
		label="${url#*://}"
		label="${label%%/*}"
	fi
	printf '[%s](%s)' "$label" "$url"
}

plugin_description() {
	local package_dir="$1"

	case "$package_dir" in
		luci-app-axonhub)
			printf 'axonhub 核心的 LuCI 管理界面与 OpenWrt 集成。\n'
			;;
		luci-app-gecoosac)
			printf 'gecoosac 核心的 LuCI 管理界面与 OpenWrt 集成。\n'
			;;
		luci-app-homeproxy)
			printf 'sing-box 核心的 LuCI 管理界面与 OpenWrt 集成。\n'
			;;
		luci-app-wolultra)
			printf 'wol 功能的 LuCI 管理界面与 OpenWrt 集成。\n'
			;;
		*)
			printf '%s 的 LuCI 管理界面与 OpenWrt 集成。\n' \
				"${package_dir#luci-app-}"
			;;
	esac
}

mapfile -t package_dirs < <(ci_discover_packages)

{
	echo '# imm-packages · AI Edition'
	echo
	echo '这是一个个人自用的 OpenWrt/ImmortalWrt 插件分享仓库。插件以实际使用需求为导向，并借助 AI 完成维护、适配、审计和自动化，因此统一标记为 **AI Edition**。'
	echo
	echo '## 插件简介'
	echo
	echo '| 插件 | 版本 | 简介 | 源码来源 |'
	echo '| --- | --- | --- | --- |'
	for package_dir in "${package_dirs[@]}"; do
		name="$(ci_package_name "$package_dir")"
		[[ "$name" == luci-app-* ]] || continue
		version="$(ci_package_version "$package_dir")"
		description="$(plugin_description "$package_dir")"
		source_url="$(package_source_url "$package_dir")"
		printf "| \`%s\` | \`%s\` | %s | %s |\n" \
			"$name" "$version" "$description" "$(source_label "$source_url")"
	done
	echo
	echo '## 核心与依赖来源'
	echo
	echo '| 软件包 | 版本 | 源码来源 |'
	echo '| --- | --- | --- |'
	for package_dir in "${package_dirs[@]}"; do
		name="$(ci_package_name "$package_dir")"
		[[ "$name" != luci-app-* ]] || continue
		version="$(ci_package_version "$package_dir")"
		source_url="$(package_source_url "$package_dir")"
		printf "| \`%s\` | \`%s\` | %s |\n" \
			"$name" "$version" "$(source_label "$source_url")"
	done
	echo
	echo '## 自动维护'
	echo
	echo 'CI 每日检查受维护的上游项目，仅在发现更新时继续构建、提交和发布。软件包目录通过 Makefile 自动发现；新增或删除软件包后，构建范围和发布资产清理会自动调整，LuCI 插件列表也会自动更新。'
	echo
	echo 'APK 发布按 ARM64 和 AMD64 分开维护；每个包名保留最近三个版本，并提供包含各软件包最新版的整合包。axonhub 核心发布仅保留最新版，发布说明包含上游最近三次提交信息。'
	echo
	echo '## License'
	echo
	echo '本仓库自有的 CI、脚本、文档及未另行声明的原创内容采用 [MIT License](LICENSE)。各插件、核心程序和预置第三方资源继续遵循其目录或上游项目声明的许可证。'
} > "$temp_file"

mv -f -- "$temp_file" "$output"
trap - EXIT
