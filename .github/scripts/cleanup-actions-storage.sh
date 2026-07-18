#!/usr/bin/env bash

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

CACHE_RETENTION_DAYS="${CACHE_RETENTION_DAYS:-3}"
CACHE_KEEP_PER_GROUP="${CACHE_KEEP_PER_GROUP:-2}"
RUN_RETENTION_DAYS="${RUN_RETENTION_DAYS:-14}"
RUN_KEEP_PER_WORKFLOW="${RUN_KEEP_PER_WORKFLOW:-10}"
DRY_RUN="${DRY_RUN:-false}"

require_positive_integer() {
	local name="$1"
	local value="$2"

	[[ "$value" =~ ^[1-9][0-9]*$ ]] || {
		printf '%s 必须是正整数：%s\n' "$name" "$value" >&2
		exit 1
	}
}

require_positive_integer CACHE_RETENTION_DAYS "$CACHE_RETENTION_DAYS"
require_positive_integer CACHE_KEEP_PER_GROUP "$CACHE_KEEP_PER_GROUP"
require_positive_integer RUN_RETENTION_DAYS "$RUN_RETENTION_DAYS"
require_positive_integer RUN_KEEP_PER_WORKFLOW "$RUN_KEEP_PER_WORKFLOW"
[[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] || {
	printf 'DRY_RUN 必须是 true 或 false：%s\n' "$DRY_RUN" >&2
	exit 1
}

cache_group() {
	case "$1" in
		immortalwrt-dl-arm64-*) printf 'immortalwrt-dl-arm64\n' ;;
		immortalwrt-dl-amd64-*) printf 'immortalwrt-dl-amd64\n' ;;
		immortalwrt-sdk-arm64-*) printf 'immortalwrt-sdk-arm64\n' ;;
		immortalwrt-sdk-amd64-*) printf 'immortalwrt-sdk-amd64\n' ;;
		setup-go-Linux-x64-*) printf 'setup-go-linux-x64\n' ;;
		node-cache-Linux-x64-pnpm-*) printf 'node-cache-linux-x64-pnpm\n' ;;
	esac
}

delete_cache() {
	local cache_id="$1"
	local key="$2"
	local reason="$3"

	printf '删除缓存：%s（%s）\n' "$key" "$reason"
	[[ "$DRY_RUN" == true ]] || gh api --method DELETE \
		"repos/$GITHUB_REPOSITORY/actions/caches/$cache_id"
}

delete_run() {
	local run_id="$1"
	local name="$2"
	local created_at="$3"

	printf '删除运行记录：%s，ID：%s，创建时间：%s\n' \
		"$name" "$run_id" "$created_at"
	[[ "$DRY_RUN" == true ]] || gh api --method DELETE \
		"repos/$GITHUB_REPOSITORY/actions/runs/$run_id"
}

now="$(date -u +%s)"
cache_cutoff=$((now - CACHE_RETENTION_DAYS * 86400))
run_cutoff=$((now - RUN_RETENTION_DAYS * 86400))
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT INT TERM

gh api --paginate \
	"repos/$GITHUB_REPOSITORY/actions/caches?per_page=100" \
	--jq '.actions_caches[] | [.id, .key, .ref, .last_accessed_at, .created_at, .size_in_bytes] | @tsv' \
	> "$temp_dir/caches.tsv"
LC_ALL=C sort -t $'\t' -k4,4r "$temp_dir/caches.tsv" \
	> "$temp_dir/caches-sorted.tsv"

declare -A cache_group_counts=()
deleted_cache_count=0
deleted_cache_bytes=0
while IFS=$'\t' read -r cache_id key _ last_accessed created_at size; do
	[[ -n "$cache_id" ]] || continue
	[[ -n "$last_accessed" ]] || last_accessed="$created_at"
	last_accessed_epoch="$(date -u -d "$last_accessed" +%s)"
	group="$(cache_group "$key")"
	reason=''

	if [[ -n "$group" ]]; then
		count=$(( ${cache_group_counts[$group]:-0} + 1 ))
		cache_group_counts["$group"]="$count"
		if (( count > CACHE_KEEP_PER_GROUP )); then
			reason="超出每类保留的最近 ${CACHE_KEEP_PER_GROUP} 份"
		fi
	fi
	if (( last_accessed_epoch < cache_cutoff )); then
		reason="超过 ${CACHE_RETENTION_DAYS} 天未使用"
	fi

	[[ -n "$reason" ]] || continue
	delete_cache "$cache_id" "$key" "$reason"
	deleted_cache_count=$((deleted_cache_count + 1))
	deleted_cache_bytes=$((deleted_cache_bytes + size))
done < "$temp_dir/caches-sorted.tsv"

gh api --paginate \
	"repos/$GITHUB_REPOSITORY/actions/runs?status=completed&per_page=100" \
	--jq '.workflow_runs[] | [.id, .workflow_id, .name, .created_at] | @tsv' \
	> "$temp_dir/runs.tsv"
LC_ALL=C sort -t $'\t' -k4,4r "$temp_dir/runs.tsv" \
	> "$temp_dir/runs-sorted.tsv"

declare -A workflow_run_counts=()
deleted_run_count=0
while IFS=$'\t' read -r run_id workflow_id name created_at; do
	[[ -n "$run_id" ]] || continue
	count=$(( ${workflow_run_counts[$workflow_id]:-0} + 1 ))
	workflow_run_counts["$workflow_id"]="$count"
	(( count > RUN_KEEP_PER_WORKFLOW )) || continue
	created_epoch="$(date -u -d "$created_at" +%s)"
	(( created_epoch < run_cutoff )) || continue

	delete_run "$run_id" "$name" "$created_at"
	deleted_run_count=$((deleted_run_count + 1))
done < "$temp_dir/runs-sorted.tsv"

mode='已执行'
[[ "$DRY_RUN" == false ]] || mode='试运行'
summary="缓存：${deleted_cache_count} 项，约 ${deleted_cache_bytes} 字节；运行记录：${deleted_run_count} 条"
printf '%s：%s\n' "$mode" "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		printf '### CI 清理结果（%s）\n\n' "$mode"
		printf -- '- 删除缓存：%s 项\n' "$deleted_cache_count"
		printf -- '- 预计释放：%s 字节\n' "$deleted_cache_bytes"
		printf -- '- 删除运行记录：%s 条\n' "$deleted_run_count"
	} >> "$GITHUB_STEP_SUMMARY"
fi
