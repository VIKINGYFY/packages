#!/usr/bin/env bash

set -euo pipefail

if (( $# < 1 || $# > 2 )); then
	printf 'Usage: %s <release-tag> [versions-to-keep]\n' "$0" >&2
	exit 2
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

RELEASE_TAG="$1"
KEEP="${2:-3}"

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || {
	printf 'Invalid retention count: %s\n' "$KEEP" >&2
	exit 1
}

release_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" --jq '.id')"
assets_file="$(mktemp)"
trap 'rm -f "$assets_file"' EXIT

gh api --paginate \
	"repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
	--jq '.[] | [.id, .name, (.label // ""), .created_at] | @tsv' > "$assets_file"

mapfile -t package_labels < <(
	awk -F '\t' '$3 ~ /^package:/ { print $3 }' "$assets_file" | sort -u
)

for package_label in "${package_labels[@]}"; do
	mapfile -t stale_assets < <(
		awk -F '\t' -v label="$package_label" '
			$3 == label && $2 ~ /\.apk$/ { print }
		' "$assets_file" |
			sort -t $'\t' -k4,4r |
			tail -n "+$((KEEP + 1))"
	)

	for asset in "${stale_assets[@]}"; do
		IFS=$'\t' read -r asset_id asset_name _ _ <<< "$asset"
		printf 'Deleting stale release asset: %s\n' "$asset_name"
		gh api --method DELETE \
			"repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
	done
done
