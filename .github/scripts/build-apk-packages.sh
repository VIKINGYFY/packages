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
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
ci_discover_packages > "$temp_dir/packages"
mapfile -t DISCOVERED_PACKAGES < "$temp_dir/packages"

declare -A DISCOVERED=()
for package in "${DISCOVERED_PACKAGES[@]}"; do
	DISCOVERED["$package"]=1
	ci_package_names "$package" > "$temp_dir/names-$package" || exit 1
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

for package in "${DISCOVERED_PACKAGES[@]}"; do
	source_dir="$REPO_ROOT/$package"
	target_dir="$SDK_ROOT/package/$package"
	name="$(ci_package_name "$package")"

	[[ -f "$source_dir/Makefile" ]] || {
		printf 'Package Makefile not found: %s\n' "$source_dir/Makefile" >&2
		exit 1
	}

	rm -rf "$target_dir"
	cp -a "$source_dir" "$target_dir"

	find "$SDK_ROOT/package/feeds" -mindepth 2 -maxdepth 2 -type l \
		\( -name "$package" -o -name "$name" \) -print0 > "$temp_dir/feed-links"
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		find "$SDK_ROOT/package/feeds" -mindepth 2 -maxdepth 2 -type l \
			-name "$name" -print0 >> "$temp_dir/feed-links"
	done < "$temp_dir/names-$package"
	sort -zu "$temp_dir/feed-links" -o "$temp_dir/feed-links"
	while IFS= read -r -d '' feed_link; do
		printf 'Removing conflicting feed package: %s\n' "$feed_link"
		unlink "$feed_link"
	done < "$temp_dir/feed-links"
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
		while IFS= read -r name; do
			[[ -n "$name" ]] || continue
			printf 'CONFIG_PACKAGE_%s=m\n' "$name"
		done < "$temp_dir/names-$package"
	done
} > "$SDK_ROOT/.config"

make -C "$SDK_ROOT" defconfig

config_package_enabled() {
	local package_name="$1"

	grep -Fqx "CONFIG_PACKAGE_${package_name}=m" "$SDK_ROOT/.config" ||
		grep -Fqx "CONFIG_PACKAGE_${package_name}=y" "$SDK_ROOT/.config"
}

for package in "${SELECTED_PACKAGES[@]}"; do
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		config_package_enabled "$name" || {
			printf 'Selected package is not enabled in SDK config: %s\n' "$name" >&2
			exit 1
		}
	done < "$temp_dir/names-$package"
	name="$(ci_package_name "$package")"
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po/zh_Hans" ]]; then
		translation_name="luci-i18n-${name#luci-app-}-zh-cn"
		config_package_enabled "$translation_name" || {
			printf 'Selected Chinese translation is not enabled in SDK config: %s\n' \
				"$translation_name" >&2
			exit 1
		}
	fi
done

for package in "${SELECTED_PACKAGES[@]}"; do
	name="$(ci_package_name "$package")"
	find "$SDK_ROOT/dl" -maxdepth 1 -type f \
		\( -name "$name-*" -o -name "$name.*" \) -print0 > "$temp_dir/cached-sources"
	while IFS= read -r -d '' cached_source; do
		printf '删除待更新软件包的旧源码缓存：%s\n' "${cached_source##*/}"
		unlink "$cached_source"
	done < "$temp_dir/cached-sources"

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
	local source_file target_file metadata actual_name selected_file=''

	find "$SDK_ROOT/bin" -type f -name "${package_name}-*.apk" -print0 > "$temp_dir/package-apks" || return 1
	while IFS= read -r -d '' source_file; do
		metadata="$("$APK_TOOL" adbdump "$source_file")"
		actual_name="$(awk '/^  name: / { sub(/^  name: /, ""); print; exit }' <<< "$metadata")"
		[[ "$actual_name" == "$package_name" ]] || continue
		found=$((found + 1))
		selected_file="$source_file"
	done < "$temp_dir/package-apks"

	if (( found != 1 )); then
		printf 'Expected exactly one APK output for package %s, found %s\n' \
			"$package_name" "$found" >&2
		exit 1
	fi

	target_file="$OUTPUT_DIR/$(basename "$selected_file")"
	if [[ -e "$target_file" ]] && ! cmp -s "$selected_file" "$target_file"; then
		printf 'Conflicting APK outputs: %s\n' "$target_file" >&2
		exit 1
	fi
	cp -p "$selected_file" "$target_file"
}

for package in "${SELECTED_PACKAGES[@]}"; do
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		copy_apk "$name"
	done < "$temp_dir/names-$package"
	name="$(ci_package_name "$package")"
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po/zh_Hans" ]]; then
		copy_apk "luci-i18n-${name#luci-app-}-zh-cn"
	fi
done

find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.apk' -print0 | sort -z > "$temp_dir/all-apks"
mapfile -d '' -t APK_FILES < "$temp_dir/all-apks"
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
