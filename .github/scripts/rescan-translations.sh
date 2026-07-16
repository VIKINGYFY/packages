#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
LUCI_I18N_DIR="${LUCI_I18N_DIR:-}"
TEMP_DIR=""
POT_TEMP=""

cleanup() {
	[[ -z "$POT_TEMP" ]] || rm -f -- "$POT_TEMP"
	[[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

if [[ -n "$LUCI_I18N_DIR" ]]; then
	SCAN_SCRIPT="$LUCI_I18N_DIR/i18n-scan.pl"
	UPDATE_SCRIPT="$LUCI_I18N_DIR/i18n-update.pl"
else
	TEMP_DIR="$(mktemp -d)"
	SCAN_SCRIPT="$TEMP_DIR/i18n-scan.pl"
	UPDATE_SCRIPT="$TEMP_DIR/i18n-update.pl"
	curl -fsSL --retry 3 \
		-o "$SCAN_SCRIPT" \
		https://github.com/openwrt/luci/raw/master/build/i18n-scan.pl
	curl -fsSL --retry 3 \
		-o "$UPDATE_SCRIPT" \
		https://github.com/openwrt/luci/raw/master/build/i18n-update.pl
fi

[[ -f "$SCAN_SCRIPT" ]] || {
	echo "Missing official i18n-scan.pl: $SCAN_SCRIPT" >&2
	exit 1
}
[[ -f "$UPDATE_SCRIPT" ]] || {
	echo "Missing official i18n-update.pl: $UPDATE_SCRIPT" >&2
	exit 1
}

cd "$REPO_ROOT"

if (( $# > 0 )); then
	PACKAGE_DIRS=("$@")
else
	mapfile -t PACKAGE_DIRS < <(
		find . -mindepth 2 -maxdepth 2 -type f -name Makefile \
			-printf '%h\n' |
			sed 's#^\./##' |
			awk -F / '$1 !~ /^\./' |
			sort -u
	)
fi

for package_dir in "${PACKAGE_DIRS[@]}"; do
	package_dir="${package_dir%/}"
	[[ -f "$package_dir/Makefile" ]] || {
		echo "Package Makefile not found: $package_dir/Makefile" >&2
		exit 1
	}
	[[ -d "$package_dir/po" ]] || continue

	templates=()
	if [[ -d "$package_dir/po/templates" ]]; then
		mapfile -t templates < <(
			find "$package_dir/po/templates" -maxdepth 1 -type f -name '*.pot' -print |
				sort
		)
	fi
	case "${#templates[@]}" in
		0)
			package_name="$(sed -n 's/^PKG_NAME:=//p' "$package_dir/Makefile" | head -n1)"
			[[ -n "$package_name" ]] || {
				echo "PKG_NAME not found in $package_dir/Makefile" >&2
				exit 1
			}
			package_name="${package_name#luci-app-}"
			package_name="${package_name#luci-theme-}"
			template="$package_dir/po/templates/$package_name.pot"
			;;
		1)
			template="${templates[0]}"
			;;
		*)
			echo "Multiple translation templates found in $package_dir" >&2
			exit 1
			;;
	esac

	sources=()
	for relative_path in \
		htdocs \
		luasrc \
		root/etc/init.d \
		root/etc/uci-defaults \
		root/etc/homeproxy/scripts \
		root/usr/bin \
		root/usr/libexec \
		root/usr/share/luci \
		root/usr/share/rpcd; do
		[[ -d "$package_dir/$relative_path" ]] && sources+=("$package_dir/$relative_path")
	done

	[[ "${#sources[@]}" -gt 0 ]] || continue
	mkdir -p -- "$(dirname -- "$template")"
	POT_TEMP="$(mktemp "${template}.tmp.XXXXXX")"
	perl "$SCAN_SCRIPT" "${sources[@]}" > "$POT_TEMP"
	[[ -s "$POT_TEMP" ]] || {
		echo "Translation scan produced an empty template for $package_dir" >&2
		exit 1
	}
	mv -f -- "$POT_TEMP" "$template"
	POT_TEMP=""

	perl "$UPDATE_SCRIPT" "$package_dir/po"
	find "$package_dir/po" -type f -name '*.po~' -delete
	while IFS= read -r -d '' po_file; do
		msgfmt --check -o /dev/null "$po_file"
	done < <(find "$package_dir/po" -type f -name '*.po' -print0)

	echo "Updated translations: $package_dir"
done
