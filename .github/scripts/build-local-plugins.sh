#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

REPO_ROOT="$CI_REPO_ROOT"
WORKSPACE_ROOT="$(dirname -- "$REPO_ROOT")"
BUILD_ROOT="${IMM_BUILD_ROOT:-/home/vking/VK/imm-main}"
TEST_ROOT="${IMM_TEST_ROOT:-/home/vking/VK/imm-packages-test-env}"
DIST_DIR="${IMM_DIST_DIR:-$WORKSPACE_ROOT/dist}"
LOCAL_PACKAGE_DIR="$BUILD_ROOT/package/imm-local"
FEED_LINK="$BUILD_ROOT/package/feeds/luci/luci-app-homeproxy"

PLUGINS=(
	luci-app-axonhub
	luci-app-gecoosac
	luci-app-homeproxy
)
APPS=(
	luci-app-axonhub
	luci-app-gecoosac
	luci-app-homeproxy
)
I18N_PACKAGES=(
	luci-i18n-axonhub-zh-cn
	luci-i18n-gecoosac-zh-cn
	luci-i18n-homeproxy-zh-cn
)
SELECTION_ARGS=()

for package in "${APPS[@]}" "${I18N_PACKAGES[@]}"; do
	SELECTION_ARGS+=("CONFIG_PACKAGE_${package}=m")
done

[[ -x "$BUILD_ROOT/staging_dir/host/bin/apk" ]] || {
	printf 'OpenWrt build environment is not ready: %s\n' "$BUILD_ROOT" >&2
	exit 1
}
[[ -x "$TEST_ROOT/bin/refresh-sources" && -x "$TEST_ROOT/bin/audit" ]] || {
	printf 'Persistent test environment is not ready: %s\n' "$TEST_ROOT" >&2
	exit 1
}

timestamp="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"
run_dir="$TEST_ROOT/runtime/build-$timestamp"
log_file="$TEST_ROOT/logs/build-all-$timestamp.log"
mkdir -p "$run_dir" "$TEST_ROOT/logs" "$DIST_DIR" "$LOCAL_PACKAGE_DIR"
exec > >(tee -a "$log_file") 2>&1

saved_feed_link="$run_dir/luci-app-homeproxy-feed-link"
feed_link_moved=false

cleanup() {
	local plugin link target

	if [[ "$feed_link_moved" == true && -L "$saved_feed_link" && ! -e "$FEED_LINK" ]]; then
		mv "$saved_feed_link" "$FEED_LINK"
	fi

	for plugin in "${PLUGINS[@]}"; do
		link="$LOCAL_PACKAGE_DIR/$plugin"
		target="$REPO_ROOT/$plugin"
		if [[ -L "$link" && "$(readlink -f -- "$link")" == "$target" ]]; then
			unlink "$link"
		fi
	done
	rmdir "$LOCAL_PACKAGE_DIR" 2>/dev/null || true
	rmdir "$run_dir" 2>/dev/null || true

	make -C "$BUILD_ROOT" -s prepare-tmpinfo >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

printf 'Refreshing official translations...\n'
LUCI_I18N_DIR="$BUILD_ROOT/feeds/luci/build" \
	"$SCRIPT_DIR/rescan-translations.sh" "${PLUGINS[@]}"

printf 'Refreshing and auditing persistent test environment...\n'
"$TEST_ROOT/bin/refresh-sources"
"$TEST_ROOT/bin/audit"
"$TEST_ROOT/bin/test-homeproxy-migration" clean
"$TEST_ROOT/bin/test-homeproxy-migration" corrupt
"$TEST_ROOT/bin/test-homeproxy-migration" post-cleanup

today="$(TZ=Asia/Shanghai date +%Y%m%d)"
VERSIONS=()
RELEASES=()

for plugin in "${PLUGINS[@]}"; do
	makefile="$REPO_ROOT/$plugin/Makefile"
	version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile" | head -n1)"
	release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile" | head -n1)"
	[[ "$version" == "$today" && "$release" =~ ^[0-9]+$ ]] || {
		printf 'Invalid version metadata in %s: %s-r%s\n' "$makefile" "$version" "$release" >&2
		exit 1
	}
	VERSIONS+=("$version")
	RELEASES+=("$release")
done

for plugin in "${PLUGINS[@]}"; do
	ln -s "$REPO_ROOT/$plugin" "$LOCAL_PACKAGE_DIR/$plugin"
done

[[ -L "$FEED_LINK" ]] || {
	printf 'Expected HomeProxy feed link was not found: %s\n' "$FEED_LINK" >&2
	exit 1
}
mv "$FEED_LINK" "$saved_feed_link"
feed_link_moved=true

printf 'Checking main and translation package selections...\n'
make -C "$BUILD_ROOT" -s prepare-tmpinfo "${SELECTION_ARGS[@]}"

for index in "${!PLUGINS[@]}"; do
	plugin="${PLUGINS[$index]}"
	app="${APPS[$index]}"
	i18n="${I18N_PACKAGES[$index]}"
	app_mapping='package-$(CONFIG_PACKAGE_'"$app"') += imm-local/'"$plugin"
	i18n_mapping='package-$(CONFIG_PACKAGE_'"$i18n"') += imm-local/'"$plugin"
	grep -Fqx "$app_mapping" "$BUILD_ROOT/tmp/.packagedeps" || {
		printf 'Main package is not mapped to local source: %s\n' "$app" >&2
		exit 1
	}
	grep -Fqx "$i18n_mapping" "$BUILD_ROOT/tmp/.packagedeps" || {
		printf 'Translation package is not mapped to local source: %s\n' "$i18n" >&2
		exit 1
	}
	printf '  selected: %s + %s -> %s\n' "$app" "$i18n" "$plugin"
done

for plugin in "${PLUGINS[@]}"; do
	printf 'Building %s...\n' "$plugin"
	make -C "$BUILD_ROOT" "package/imm-local/$plugin/clean" "${SELECTION_ARGS[@]}"
	make -C "$BUILD_ROOT" -j1 "package/imm-local/$plugin/compile" \
		"${SELECTION_ARGS[@]}" V=s
done

APK_TOOL="$BUILD_ROOT/staging_dir/host/bin/apk"
COLLECTED=()

copy_package() {
	local package="$1" version="$2" release="$3"
	local source_file target_file metadata actual_name actual_version
	local -a candidates=()

	mapfile -d '' -t candidates < <(
		find "$BUILD_ROOT/bin" -type f -name "${package}-${version}-r${release}.apk" -print0
	)
	(( ${#candidates[@]} == 1 )) || {
		printf 'Expected one APK for %s %s-r%s, found %s\n' \
			"$package" "$version" "$release" "${#candidates[@]}" >&2
		exit 1
	}

	source_file="${candidates[0]}"
	metadata="$("$APK_TOOL" adbdump "$source_file")"
	actual_name="$(awk '/^  name: / { sub(/^  name: /, ""); print; exit }' <<< "$metadata")"
	actual_version="$(awk '/^  version: / { sub(/^  version: /, ""); print; exit }' <<< "$metadata")"
	[[ "$actual_name" == "$package" && "$actual_version" == "$version-r$release" ]] || {
		printf 'Unexpected APK metadata: %s %s\n' "$actual_name" "$actual_version" >&2
		exit 1
	}

	target_file="$DIST_DIR/$(basename -- "$source_file")"
	if [[ -e "$target_file" ]]; then
		if cmp -s "$source_file" "$target_file"; then
			printf 'Keeping existing identical package: %s\n' "$target_file"
		elif cmp -s \
			<("$APK_TOOL" adbdump "$source_file" | sed '/^# sig /d') \
			<("$APK_TOOL" adbdump "$target_file" | sed '/^# sig /d'); then
			printf 'Keeping existing package with identical payload: %s\n' "$target_file"
		else
			printf 'Refusing to overwrite a different historical package: %s\n' "$target_file" >&2
			exit 1
		fi
	else
		cp -p "$source_file" "$target_file"
	fi
	COLLECTED+=("$target_file")
}

for index in "${!PLUGINS[@]}"; do
	copy_package "${APPS[$index]}" "${VERSIONS[$index]}" "${RELEASES[$index]}"
	copy_package "${I18N_PACKAGES[$index]}" "${VERSIONS[$index]}" "${RELEASES[$index]}"
done

printf 'Build completed and copied to %s:\n' "$DIST_DIR"
for file in "${COLLECTED[@]}"; do
	printf '  %s  %s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "$(basename -- "$file")"
done
printf 'Build log: %s\n' "$log_file"
