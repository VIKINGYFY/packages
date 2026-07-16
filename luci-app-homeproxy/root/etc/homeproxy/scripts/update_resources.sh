#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="homeproxy"

RESOURCES_DIR="${RESOURCES_DIR:-/etc/$NAME/resources}"
DASHBOARD_DIR="${DASHBOARD_DIR:-/etc/$NAME/dashboard}"
RUN_DIR="${RUN_DIR:-/var/run/$NAME}"
LOG_PATH="$RUN_DIR/$NAME.log"
RESULT_PATH="$RUN_DIR/update_resources.result"
REPO_NAME="Loyalsoldier/surge-rules"
REPO_BRANCH="release"
GEOSITE_REPO="SagerNet/sing-geosite"
GEOSITE_BRANCH="rule-set-unstable"
IP_RESOURCES="china_ip4 china_ip6"
IP_RULESET="geoip_cn.json"
SOURCE_BASE="${SOURCE_BASE:-https://cdn.jsdelivr.net/gh/$REPO_NAME@$REPO_BRANCH}"
GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/$GEOSITE_REPO@$GEOSITE_BRANCH/geosite-cn.srs}"
IP_VERSION_URL="${IP_VERSION_URL:-https://github.com/$REPO_NAME/releases/latest}"
GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/$GEOSITE_REPO/releases/latest}"
DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
USER_AGENT="HomeProxy resource updater"
UPDATE_PROXY="${HOMEPROXY_UPDATE_PROXY:-}"

if ! mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR" "$RUN_DIR"; then
	printf '%s\n' "Failed to prepare HomeProxy resource directories." >&2
	exit 1
fi

log() {
	printf '%s %s\n' "$(date "+%Y-%m-%d %H:%M:%S")" "$*" >> "$LOG_PATH"
}

UPDATED_BRANCHES=""
FAILED_BRANCHES=""
CORE_UPDATED=0
DASHBOARD_UPDATED=0

append_result() {
	local current="$1" value="$2"

	if [ -n "$current" ]; then
		printf '%s,%s' "$current" "$value"
	else
		printf '%s' "$value"
	fi
}

mark_updated() {
	UPDATED_BRANCHES="$(append_result "$UPDATED_BRANCHES" "$1")"
}

mark_failed() {
	FAILED_BRANCHES="$(append_result "$FAILED_BRANCHES" "$1")"
}

write_result() {
	local status="$1"

	printf 'status=%s\ncore_updated=%s\ndashboard_updated=%s\nupdated=%s\nfailed=%s\n' \
		"$status" "$CORE_UPDATED" "$DASHBOARD_UPDATED" \
		"$UPDATED_BRANCHES" "$FAILED_BRANCHES" > "$RESULT_PATH"
}

finish() {
	write_result "$1"
	exit "$1"
}

run_curl() {
	if [ -n "$UPDATE_PROXY" ]; then
		/usr/bin/curl --proxy "$UPDATE_PROXY" "$@"
	else
		/usr/bin/curl "$@"
	fi
}

download() {
	local source_url="$1"
	local target_file="$2"

	run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 60 \
		-A "$USER_AGENT" \
		-o "$target_file" "$source_url" && [ -s "$target_file" ]
}

fetch_release_version() {
	local release_url="$1"
	local effective_url

	effective_url="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" -o "/dev/null" -w '%{url_effective}' "$release_url")" || return 1
	local release_version="${effective_url##*/}"
	case "$release_version" in
	''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$release_version"
}

fetch_dashboard_version() {
	local feed version

	feed="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 30 -A "$USER_AGENT" "$DASHBOARD_VERSION_URL")" || return 1
	version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
		/<updated>/ {
			version = $3
			gsub(/[-:TZ]/, "", version)
			print version
			exit
		}
	')"
	case "$version" in
	??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

versioned_url() {
	case "$1" in
	http://*|https://*) printf '%s?v=%s' "$1" "$2" ;;
	*) printf '%s' "$1" ;;
	esac
}

exec 9>"$RUN_DIR/update_resources.lock"
if ! flock -n 9 > "/dev/null" 2>&1; then
	log "[RESOURCES] A task is already running."
	exit 2
fi
rm -f "$RESULT_PATH"
if [ -e "$DASHBOARD_DIR/.etag" ]; then
	rm -f "$DASHBOARD_DIR/.etag"
	DASHBOARD_UPDATED=1
fi

IP_CURRENT=1
GEOSITE_CURRENT=1
DASHBOARD_CURRENT=1

if NEW_IP_VER="$(fetch_release_version "$IP_VERSION_URL")"; then
	for RESOURCE in $IP_RESOURCES; do
		OLD_VER="$(cat "$RESOURCES_DIR/$RESOURCE.ver" 2>/dev/null || echo "NOT FOUND")"
		if [ -s "$RESOURCES_DIR/$RESOURCE.txt" ] && [ "$OLD_VER" = "$NEW_IP_VER" ]; then
			log "[$RESOURCE] Current version: $NEW_IP_VER."
		else
			IP_CURRENT=0
			log "[$RESOURCE] Local version: $OLD_VER, latest version: $NEW_IP_VER."
		fi
	done
	if [ ! -s "$RESOURCES_DIR/$IP_RULESET" ]; then
		IP_CURRENT=0
		log "[geoip_cn] Local rule set is missing."
	fi
else
	IP_CURRENT=-1
	mark_failed "china_ip"
	log "[china_ip] Failed to get the latest version; continuing with other resources."
fi

if NEW_GEOSITE_VER="$(fetch_release_version "$GEOSITE_VERSION_URL")"; then
	OLD_VER="$(cat "$RESOURCES_DIR/geosite_cn.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$RESOURCES_DIR/geosite_cn.srs" ] && [ "$OLD_VER" = "$NEW_GEOSITE_VER" ]; then
		log "[geosite_cn] Current version: $NEW_GEOSITE_VER."
	else
		GEOSITE_CURRENT=0
		log "[geosite_cn] Local version: $OLD_VER, latest version: $NEW_GEOSITE_VER."
	fi
else
	GEOSITE_CURRENT=-1
	mark_failed "geosite_cn"
	log "[geosite_cn] Failed to get the latest version; continuing with other resources."
fi

if NEW_DASHBOARD_VER="$(fetch_dashboard_version)"; then
	OLD_VER="$(cat "$DASHBOARD_DIR/dashboard.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$DASHBOARD_DIR/index.html" ] && [ "$OLD_VER" = "$NEW_DASHBOARD_VER" ]; then
		log "[dashboard] Current version: $NEW_DASHBOARD_VER."
	else
		DASHBOARD_CURRENT=0
		log "[dashboard] Local version: $OLD_VER, latest version: $NEW_DASHBOARD_VER."
	fi
else
	DASHBOARD_CURRENT=-1
	mark_failed "dashboard"
	log "[dashboard] Failed to get the latest version; continuing with other resources."
fi

if [ "$IP_CURRENT" -eq 1 ] && [ "$GEOSITE_CURRENT" -eq 1 ] && \
	[ "$DASHBOARD_CURRENT" -eq 1 ]; then
	log "[RESOURCES] You're already at the latest version."
	finish 3
fi

TMP_DIR="$(mktemp -d "$RUN_DIR/resources-update.XXXXXX")" || {
	log "[RESOURCES] Failed to prepare the temporary update directory."
	finish 1
}
DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
cleanup() {
	rm -rf "$TMP_DIR" "$DASHBOARD_STAGE"
}
trap cleanup EXIT INT TERM

if [ "$IP_CURRENT" -eq 0 ]; then
	IP_READY=1
	if ! download "$(versioned_url "$SOURCE_BASE/cncidr.txt" "$NEW_IP_VER")" "$TMP_DIR/cncidr.txt"; then
		log "[china_ip] Update failed while downloading the source list."
		IP_READY=0
	elif ! awk -F, -v ipv4="$TMP_DIR/china_ip4.txt" -v ipv6="$TMP_DIR/china_ip6.txt" '
		$1 == "IP-CIDR" { print $2 > ipv4 }
		$1 == "IP-CIDR6" { print $2 > ipv6 }
	' "$TMP_DIR/cncidr.txt"; then
		log "[china_ip] Update failed while processing the source list."
		IP_READY=0
	fi

	if [ "$IP_READY" -eq 1 ]; then
		for RESOURCE in $IP_RESOURCES; do
			if [ ! -s "$TMP_DIR/$RESOURCE.txt" ] || \
			   ! printf '%s\n' "$NEW_IP_VER" > "$TMP_DIR/$RESOURCE.ver"; then
				log "[$RESOURCE] Update failed: empty or incomplete processed list."
				IP_READY=0
				break
			fi
		done
	fi

	if [ "$IP_READY" -eq 1 ] && ! awk '
		BEGIN {
			print "{\"version\":5,\"rules\":[{\"ip_cidr\":["
			first = 1
		}
		NF {
			printf "%s\"%s\"", first ? "" : ",", $0
			first = 0
		}
		END { print "]}]}" }
	' "$TMP_DIR/china_ip4.txt" "$TMP_DIR/china_ip6.txt" > "$TMP_DIR/$IP_RULESET"; then
		log "[geoip_cn] Update failed while generating the source rule set."
		IP_READY=0
	elif [ "$IP_READY" -eq 1 ] && [ ! -s "$TMP_DIR/$IP_RULESET" ]; then
		log "[geoip_cn] Update failed: empty generated rule set."
		IP_READY=0
	fi

	if [ "$IP_READY" -eq 1 ]; then
		for RESOURCE in $IP_RESOURCES; do
			cp "$TMP_DIR/$RESOURCE.txt" "$RESOURCES_DIR/$RESOURCE.txt" && \
				cp "$TMP_DIR/$RESOURCE.ver" "$RESOURCES_DIR/$RESOURCE.ver" || IP_READY=0
		done
		cp "$TMP_DIR/$IP_RULESET" "$RESOURCES_DIR/$IP_RULESET" || IP_READY=0
		chmod 0644 "$RESOURCES_DIR"/china_ip*.txt "$RESOURCES_DIR"/china_ip*.ver \
			"$RESOURCES_DIR/$IP_RULESET" 2>"/dev/null"
		if [ "$IP_READY" -eq 1 ]; then
			for RESOURCE in $IP_RESOURCES; do
				log "[$RESOURCE] Successfully updated."
			done
			CORE_UPDATED=1
			mark_updated "china_ip"
		else
			log "[china_ip] Update failed while installing generated files."
		fi
	fi

	if [ "$IP_READY" -ne 1 ]; then
		mark_failed "china_ip"
	fi
fi

if [ "$GEOSITE_CURRENT" -eq 0 ]; then
	if ! download "$(versioned_url "$GEOSITE_SOURCE" "$NEW_GEOSITE_VER")" "$TMP_DIR/geosite_cn.srs"; then
		log "[geosite_cn] Update failed while downloading the domain rule set."
		mark_failed "geosite_cn"
	elif ! printf '%s\n' "$NEW_GEOSITE_VER" > "$TMP_DIR/geosite_cn.ver" || \
	     ! cp "$TMP_DIR/geosite_cn.srs" "$RESOURCES_DIR/geosite_cn.srs" || \
	     ! cp "$TMP_DIR/geosite_cn.ver" "$RESOURCES_DIR/geosite_cn.ver"; then
		log "[geosite_cn] Update failed while installing the domain rule set."
		mark_failed "geosite_cn"
	else
		chmod 0644 "$RESOURCES_DIR/geosite_cn.srs" "$RESOURCES_DIR/geosite_cn.ver"
		log "[geosite_cn] Successfully updated."
		CORE_UPDATED=1
		mark_updated "geosite_cn"
	fi
fi

if [ "$DASHBOARD_CURRENT" -eq 0 ]; then
	DASHBOARD_READY=1
	if ! download "$(versioned_url "$DASHBOARD_SOURCE" "$NEW_DASHBOARD_VER")" "$TMP_DIR/dashboard.zip"; then
		log "[dashboard] Update failed while downloading the dashboard."
		DASHBOARD_READY=0
	elif ! mkdir -p "$TMP_DIR/dashboard" || \
	   ! unzip -q "$TMP_DIR/dashboard.zip" -d "$TMP_DIR/dashboard"; then
		log "[dashboard] Update failed while extracting the dashboard."
		DASHBOARD_READY=0
	fi
	DASHBOARD_SOURCE_DIR=""
	if [ "$DASHBOARD_READY" -eq 1 ]; then
		for DASHBOARD_INDEX in "$TMP_DIR/dashboard/index.html" "$TMP_DIR"/dashboard/*/index.html; do
			if [ -f "$DASHBOARD_INDEX" ]; then
				DASHBOARD_SOURCE_DIR="${DASHBOARD_INDEX%/index.html}"
				break
			fi
		done
		if [ ! -f "$DASHBOARD_SOURCE_DIR/index.html" ]; then
			log "[dashboard] Update failed: invalid dashboard archive."
			DASHBOARD_READY=0
		fi
	fi
	if [ "$DASHBOARD_READY" -eq 1 ]; then
		rm -rf "$DASHBOARD_STAGE"
		if ! mkdir -p "$DASHBOARD_STAGE" || \
	   ! cp -a "$DASHBOARD_SOURCE_DIR/." "$DASHBOARD_STAGE/"; then
			log "[dashboard] Update failed while staging the dashboard."
			DASHBOARD_READY=0
		elif ! printf '%s\n' "$NEW_DASHBOARD_VER" > "$DASHBOARD_STAGE/dashboard.ver"; then
			log "[dashboard] Update failed while writing its version."
			DASHBOARD_READY=0
		else
			chmod -R a+rX "$DASHBOARD_STAGE"
		fi
	fi
	if [ "$DASHBOARD_READY" -eq 1 ]; then
		rm -rf "$DASHBOARD_DIR"
		if mv "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
			log "[dashboard] Successfully updated."
			DASHBOARD_UPDATED=1
			mark_updated "dashboard"
		else
			log "[dashboard] Update failed: unable to replace dashboard files."
			DASHBOARD_READY=0
		fi
	fi
	if [ "$DASHBOARD_READY" -ne 1 ]; then
		mark_failed "dashboard"
	fi
fi

if [ -n "$FAILED_BRANCHES" ]; then
	if [ -n "$UPDATED_BRANCHES" ]; then
		log "[RESOURCES] Partially updated ($UPDATED_BRANCHES); failed branches: $FAILED_BRANCHES."
		finish 4
	fi
	log "[RESOURCES] Update failed for: $FAILED_BRANCHES."
	finish 1
fi

finish 0
