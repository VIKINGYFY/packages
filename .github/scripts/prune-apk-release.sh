#!/usr/bin/env bash

set -euo pipefail

if (( $# < 1 || $# > 3 )); then
	printf 'Usage: %s <release-tag> [versions-to-keep] [latest-assets-file]\n' "$0" >&2
	exit 2
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
RELEASE_TAG="$1"
KEEP="${2:-3}"
LATEST_ASSETS_FILE="${3:-}"

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || {
	printf 'Invalid retention count: %s\n' "$KEEP" >&2
	exit 1
}

release_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" --jq '.id')"
assets_file="$(mktemp)"
classified_file="$(mktemp)"
trap 'rm -f "$assets_file" "$classified_file"' EXIT

mapfile -t package_dirs < <(
	find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name Makefile \
		-printf '%h\n' |
		sed "s#^$REPO_ROOT/##" |
		awk -F / '$1 !~ /^\./' |
		sort -u
)

package_names=()
for package_dir in "${package_dirs[@]}"; do
	name="$(sed -n 's/^PKG_NAME:=//p' "$REPO_ROOT/$package_dir/Makefile" | head -n1)"
	[[ -n "$name" ]] || {
		printf 'PKG_NAME not found in %s/Makefile\n' "$package_dir" >&2
		exit 1
	}
	package_names+=("$name")
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package_dir/po" ]]; then
		package_names+=("luci-i18n-${name#luci-app-}-zh-cn")
	fi
done

mapfile -t package_names < <(
	printf '%s\n' "${package_names[@]}" |
		awk 'NF { print length($0) "\t" $0 }' |
		sort -t $'\t' -k1,1nr -k2,2 |
		cut -f2- |
		awk '!seen[$0]++'
)

gh api --paginate \
	"repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
	--jq '.[] | [.id, .name, (if (.label // "") == "" then "__NO_LABEL__" else .label end), .created_at] | @tsv' \
	> "$assets_file"

while IFS=$'\t' read -r asset_id asset_name asset_label created_at; do
	[[ "$asset_name" == *.apk ]] || continue
	[[ "$asset_label" != __NO_LABEL__ ]] || asset_label=""
	name=""
	if [[ "$asset_label" == package:* ]]; then
		name="${asset_label#package:}"
	else
		for candidate in "${package_names[@]}"; do
			if [[ "$asset_name" == "$candidate-"*.apk ]]; then
				name="$candidate"
				break
			fi
		done
	fi

	if [[ -z "$name" ]]; then
		printf 'Unable to identify release asset package: %s\n' "$asset_name" >&2
		continue
	fi
	printf '%s\t%s\t%s\t%s\n' \
		"$asset_id" "$asset_name" "$name" "$created_at" >> "$classified_file"

	if [[ -n "$asset_label" ]]; then
		printf 'Clearing legacy release asset label: %s\n' "$asset_name"
		gh api --method PATCH \
			"repos/$GITHUB_REPOSITORY/releases/assets/$asset_id" \
			-f name="$asset_name" -f label= >/dev/null
	fi
done < "$assets_file"

mapfile -t packages < <(
	awk -F '\t' '{ print $3 }' "$classified_file" | sort -u
)

[[ -z "$LATEST_ASSETS_FILE" ]] || : > "$LATEST_ASSETS_FILE"

for package in "${packages[@]}"; do
	mapfile -t package_assets < <(
		awk -F '\t' -v package="$package" '$3 == package { print }' "$classified_file" |
			sort -t $'\t' -k4,4r
	)
	if [[ -n "$LATEST_ASSETS_FILE" ]]; then
		printf '%s\n' "${package_assets[0]}" >> "$LATEST_ASSETS_FILE"
	fi
	stale_assets=("${package_assets[@]:KEEP}")

	for asset in "${stale_assets[@]}"; do
		IFS=$'\t' read -r asset_id asset_name _ _ <<< "$asset"
		printf 'Deleting stale release asset: %s\n' "$asset_name"
		gh api --method DELETE \
			"repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
	done
done
