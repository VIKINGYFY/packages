#!/usr/bin/env bash

set -euo pipefail

if (( $# < 5 )); then
	printf 'Usage: %s <sdk-root> <output-dir> <target> <subtarget> <package>...\n' "$0" >&2
	exit 2
fi

SDK_ROOT="$(realpath "$1")"
OUTPUT_DIR="$2"
TARGET="$3"
SUBTARGET="$4"
shift 4

[[ "$TARGET" =~ ^[a-z0-9_]+$ && "$SUBTARGET" =~ ^[a-z0-9_]+$ ]] || {
	printf 'Invalid target: %s/%s\n' "$TARGET" "$SUBTARGET" >&2
	exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"
REPO_ROOT="$CI_REPO_ROOT"
mapfile -t DISCOVERED_PACKAGES < <(ci_discover_packages)

declare -A DISCOVERED=()
for package in "${DISCOVERED_PACKAGES[@]}"; do
	DISCOVERED["$package"]=1
done

SELECTED_PACKAGES=("$@")
BUILD_ZH_HANS=false
for package in "${SELECTED_PACKAGES[@]}"; do
	if [[ -z "${DISCOVERED[$package]:-}" ]]; then
		printf 'Package directory was not discovered: %s\n' "$package" >&2
		exit 1
	fi
	name="$(ci_package_name "$package")"
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po/zh_Hans" ]]; then
		BUILD_ZH_HANS=true
	fi
done

if [[ ! -x "$SDK_ROOT/scripts/feeds" ]]; then
	printf 'Invalid ImmortalWrt SDK root: %s\n' "$SDK_ROOT" >&2
	exit 1
fi

package_name() {
	ci_package_name "$1"
}

for package in "${DISCOVERED_PACKAGES[@]}"; do
	source_dir="$REPO_ROOT/$package"
	target_dir="$SDK_ROOT/package/$package"
	name="$(package_name "$package")"

	[[ -f "$source_dir/Makefile" ]] || {
		printf 'Package Makefile not found: %s\n' "$source_dir/Makefile" >&2
		exit 1
	}

	rm -rf "$target_dir"
	cp -a "$source_dir" "$target_dir"

	while IFS= read -r -d '' feed_link; do
		printf 'Removing conflicting feed package: %s\n' "$feed_link"
		unlink "$feed_link"
	done < <(
		find "$SDK_ROOT/package/feeds" -mindepth 2 -maxdepth 2 -type l \
			\( -name "$package" -o -name "$name" \) -print0 2>/dev/null
	)
done

{
	printf '%s\n' \
		"CONFIG_TARGET_${TARGET}=y" \
		"CONFIG_TARGET_${TARGET}_${SUBTARGET}=y" \
		'CONFIG_TARGET_MULTI_PROFILE=y' \
		'CONFIG_DEVEL=y' \
		'CONFIG_BUILD_LOG=y'
	if [[ "$BUILD_ZH_HANS" == true ]]; then
		printf '%s\n' 'CONFIG_LUCI_LANG_zh_Hans=m'
	fi

	for package in "${SELECTED_PACKAGES[@]}"; do
		name="$(package_name "$package")"
		printf 'CONFIG_PACKAGE_%s=m\n' "$name"
	done
} > "$SDK_ROOT/.config"

make -C "$SDK_ROOT" defconfig

for package in "${SELECTED_PACKAGES[@]}"; do
	name="$(package_name "$package")"
	while IFS= read -r -d '' cached_source; do
		printf '删除待更新软件包的旧源码缓存：%s\n' "${cached_source##*/}"
		unlink "$cached_source"
	done < <(
		find "$SDK_ROOT/dl" -maxdepth 1 -type f \
			\( -name "$name-*" -o -name "$name.*" \) -print0
	)

	make -C "$SDK_ROOT" "package/$package/clean"
	make -C "$SDK_ROOT" -j"$(nproc)" "package/$package/compile" ||
		make -C "$SDK_ROOT" -j1 "package/$package/compile" V=s
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

APK_TOOL="$SDK_ROOT/staging_dir/host/bin/apk"
[[ -x "$APK_TOOL" ]] || {
	printf 'SDK apk tool not found: %s\n' "$APK_TOOL" >&2
	exit 1
}

copy_apk() {
	local package_name="$1"
	local found=0
	local source_file target_file metadata actual_name

	while IFS= read -r -d '' source_file; do
		metadata="$("$APK_TOOL" adbdump "$source_file")"
		actual_name="$(awk '/^  name: / { sub(/^  name: /, ""); print; exit }' <<< "$metadata")"
		[[ "$actual_name" == "$package_name" ]] || continue
		found=1
		target_file="$OUTPUT_DIR/$(basename "$source_file")"

		if [[ -e "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
			printf 'Conflicting APK outputs: %s\n' "$target_file" >&2
			exit 1
		fi

		cp -p "$source_file" "$target_file"
	done < <(find "$SDK_ROOT/bin" -type f -name "${package_name}-*.apk" -print0)

	if (( found == 0 )); then
		printf 'APK output not found for package: %s\n' "$package_name" >&2
		exit 1
	fi
}

for package in "${SELECTED_PACKAGES[@]}"; do
	name="$(package_name "$package")"
	copy_apk "$name"
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po/zh_Hans" ]]; then
		copy_apk "luci-i18n-${name#luci-app-}-zh-cn"
	fi
done

mapfile -d '' -t APK_FILES < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z)
(( ${#APK_FILES[@]} > 0 )) || {
	printf 'No APK files were collected.\n' >&2
	exit 1
}

if [[ -f "$SDK_ROOT/public-key.pem" ]]; then
	"$APK_TOOL" verify --keys-dir "$SDK_ROOT" "${APK_FILES[@]}"
fi

manifest="$OUTPUT_DIR/APK-MANIFEST.tsv"
: > "$manifest"

for apk_file in "${APK_FILES[@]}"; do
	metadata="$("$APK_TOOL" adbdump "$apk_file")"
	name="$(awk '/^  name: / { sub(/^  name: /, ""); print; exit }' <<< "$metadata")"
	version="$(awk '/^  version: / { sub(/^  version: /, ""); print; exit }' <<< "$metadata")"
	[[ -n "$name" && -n "$version" ]] || {
		printf 'Unable to read APK metadata: %s\n' "$apk_file" >&2
		exit 1
	}
	printf '%s\t%s\t%s\t%s\n' \
		"$(basename "$apk_file")" \
		"$name" \
		"$version" \
		"$(sha256sum "$apk_file" | cut -d' ' -f1)" \
		>> "$manifest"
done

(
	cd "$OUTPUT_DIR"
	sha256sum -- *.apk > SHA256SUMS
)

printf 'Collected APK files:\n'
printf '  %s\n' "${APK_FILES[@]##*/}"
