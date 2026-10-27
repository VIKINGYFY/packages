#!/usr/bin/env bash

set -euo pipefail

if (( $# < 1 || $# > 3 )); then
	printf 'Usage: %s <release-tag> [versions-to-keep] [latest-assets-file]\n' "$0" >&2
	exit 2
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"
REPO_ROOT="$CI_REPO_ROOT"
RELEASE_TAG="$1"
KEEP="${2:-1}"
LATEST_ASSETS_FILE="${3:-}"
APK_TOOL="${APK_TOOL:-apk}"

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || {
	printf 'Invalid retention count: %s\n' "$KEEP" >&2
	exit 1
}

command -v "$APK_TOOL" >/dev/null || {
	printf 'APK version tool not found: %s\n' "$APK_TOOL" >&2
	exit 1
}

release_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" --jq '.id')"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
assets_file="$temp_dir/assets.tsv"
classified_file="$temp_dir/classified.tsv"
: > "$classified_file"
: > "$temp_dir/removed.tsv"
: > "$temp_dir/stale.tsv"
: > "$temp_dir/labels.tsv"
: > "$temp_dir/latest.tsv"

ci_discover_packages > "$temp_dir/packages"
mapfile -t package_dirs < "$temp_dir/packages"

package_names=()
for package_dir in "${package_dirs[@]}"; do
	ci_package_names "$package_dir" > "$temp_dir/names-$package_dir" || exit 1
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		package_names+=("$name")
	done < "$temp_dir/names-$package_dir"
	name="$(ci_package_name "$package_dir")"
	if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package_dir/po" ]]; then
		package_names+=("luci-i18n-${name#luci-app-}-zh-cn")
	fi
done

printf '%s\n' "${package_names[@]}" |
	awk 'NF { print length($0) "\t" $0 }' |
	sort -t $'\t' -k1,1nr -k2,2 |
	cut -f2- |
	awk '!seen[$0]++' > "$temp_dir/package-names"
mapfile -t package_names < "$temp_dir/package-names"

declare -A current_package_names=()
for name in "${package_names[@]}"; do
	current_package_names["$name"]=1
done

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

	if [[ -z "$name" || -z "${current_package_names[$name]:-}" ]]; then
		printf '%s\t%s\n' "$asset_id" "$asset_name" >> "$temp_dir/removed.tsv"
		continue
	fi
	[[ "$asset_name" == "$name-"*.apk ]] || {
		printf 'Release asset name does not match package: %s (%s)\n' "$asset_name" "$name" >&2
		exit 1
	}
	version="${asset_name#"$name-"}"
	version="${version%.apk}"
	"$APK_TOOL" version --check "$version"
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$asset_id" "$asset_name" "$name" "$created_at" "$version" >> "$classified_file"

	if [[ -n "$asset_label" ]]; then
		printf '%s\t%s\n' "$asset_id" "$asset_name" >> "$temp_dir/labels.tsv"
	fi
done < "$assets_file"

awk -F '\t' '{ print $3 }' "$classified_file" | sort -u > "$temp_dir/classified-packages"
mapfile -t packages < "$temp_dir/classified-packages"

for package in "${packages[@]}"; do
	# Newer uploads win only when APK considers the versions equal.
	awk -F '\t' -v package="$package" '$3 == package { print }' "$classified_file" |
		sort -t $'\t' -k4,4r -k1,1nr > "$temp_dir/package-assets"
	mapfile -t package_assets < "$temp_dir/package-assets"
	ordered_assets=()
	for asset in "${package_assets[@]}"; do
		version="${asset##*$'\t'}"
		index=0
		while (( index < ${#ordered_assets[@]} )); do
			other_version="${ordered_assets[$index]##*$'\t'}"
			comparison="$("$APK_TOOL" version --test "$version" "$other_version")"
			[[ "$comparison" != '>' ]] || break
			index=$((index + 1))
		done
		ordered_assets=("${ordered_assets[@]:0:index}" "$asset" "${ordered_assets[@]:index}")
	done
	printf '%s\n' "${ordered_assets[0]%$'\t'*}" >> "$temp_dir/latest.tsv"
	stale_assets=("${ordered_assets[@]:KEEP}")

	for asset in "${stale_assets[@]}"; do
		IFS=$'\t' read -r asset_id asset_name _ <<< "$asset"
		printf '%s\t%s\n' "$asset_id" "$asset_name" >> "$temp_dir/stale.tsv"
	done
done

while IFS=$'\t' read -r asset_id asset_name; do
	printf 'Clearing legacy release asset label: %s\n' "$asset_name"
	gh api --method PATCH \
		"repos/$GITHUB_REPOSITORY/releases/assets/$asset_id" \
		-f name="$asset_name" -f label= >/dev/null
done < "$temp_dir/labels.tsv"

cat "$temp_dir/removed.tsv" "$temp_dir/stale.tsv" > "$temp_dir/delete.tsv"
while IFS=$'\t' read -r asset_id asset_name; do
	printf 'Deleting obsolete release asset: %s\n' "$asset_name"
	gh api --method DELETE \
		"repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
done < "$temp_dir/delete.tsv"

if [[ -n "$LATEST_ASSETS_FILE" ]]; then
	cp "$temp_dir/latest.tsv" "$LATEST_ASSETS_FILE"
fi
