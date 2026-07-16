#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"

cd "$REPO_ROOT"

for package_dir in */; do
	[[ "$package_dir" == .* ]] && continue

	executable_dirs=(
		"${package_dir}root/bin"
		"${package_dir}root/sbin"
		"${package_dir}root/usr/bin"
		"${package_dir}root/usr/sbin"
		"${package_dir}root/usr/libexec"
		"${package_dir}root/etc/hotplug.d"
		"${package_dir}root/etc/init.d"
		"${package_dir}root/etc/uci-defaults"
		"${package_dir}root/etc/"*/scripts
	)

	for directory in "${executable_dirs[@]}"; do
		[[ -d "$directory" ]] || continue
		find "$directory" -type d -exec chmod 0755 {} +
		find "$directory" -type f ! -perm /111 -print -exec chmod 0755 {} +
	done
done
