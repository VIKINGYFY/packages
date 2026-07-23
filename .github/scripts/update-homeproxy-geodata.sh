#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
RESOURCES_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/resources"
DASHBOARD_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/dashboard"

IP_REPO="${IP_REPO:-Loyalsoldier/surge-rules}"
IP_BRANCH="${IP_BRANCH:-release}"
GEOSITE_REPO="${GEOSITE_REPO:-SagerNet/sing-geosite}"
GEOSITE_BRANCH="${GEOSITE_BRANCH:-rule-set-unstable}"
IP_SOURCE="${IP_SOURCE:-https://cdn.jsdelivr.net/gh/${IP_REPO}@${IP_BRANCH}/cncidr.txt}"
GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/${GEOSITE_REPO}@${GEOSITE_BRANCH}/geosite-cn.srs}"
IP_VERSION_URL="${IP_VERSION_URL:-https://github.com/${IP_REPO}/releases/latest}"
GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/${GEOSITE_REPO}/releases/latest}"
DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
USER_AGENT="${USER_AGENT:-HomeProxy resource preset}"

TEMP_DIR="$(mktemp -d)" || {
	echo "Failed to prepare temporary resource directory." >&2
	exit 1
}
DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
trap 'rm -rf -- "$TEMP_DIR" "$DASHBOARD_STAGE"' EXIT INT TERM

warn() {
	echo "WARNING: $*" >&2
	if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
		echo "::warning::$*"
	fi
}

set_output() {
	local name="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
	fi
}

fetch_release_version() {
	local effective_url version
	effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
		--retry-delay 1 --connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" -o /dev/null -w '%{url_effective}' "$1")" || return 1
	version="${effective_url##*/}"
	case "$version" in
		''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

fetch_dashboard_version() {
	local feed version
	feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
		--retry-delay 1 --connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" "$DASHBOARD_VERSION_URL")" || return 1
	version="$(awk -F '[<>]' '
		/<updated>/ {
			version = $3
			gsub(/[-:TZ]/, "", version)
			print version
			exit
		}
	' <<<"$feed")"
	case "$version" in
		??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
		*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

download() {
	curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 60 -A "$USER_AGENT" -o "$2" "$1" &&
		test -s "$2"
}

mkdir -p -- "$RESOURCES_DIR" "$DASHBOARD_DIR"
update_failed=0
ip_version=""
geosite_version=""
dashboard_version=""

ip_ready=1
ip_version="$(fetch_release_version "$IP_VERSION_URL")" || ip_ready=0
if [[ "$ip_ready" -eq 1 ]] && ! download "${IP_SOURCE}?v=${ip_version}" "$TEMP_DIR/cncidr.txt"; then
	ip_ready=0
fi
if [[ "$ip_ready" -eq 1 ]] && ! awk -F, \
	-v ipv4="$TEMP_DIR/china_ip4.txt" -v ipv6="$TEMP_DIR/china_ip6.txt" '
	$1 == "IP-CIDR" { print $2 > ipv4 }
	$1 == "IP-CIDR6" { print $2 > ipv6 }
' "$TEMP_DIR/cncidr.txt"; then
	ip_ready=0
fi
[[ "$ip_ready" -eq 0 || -s "$TEMP_DIR/china_ip4.txt" ]] || ip_ready=0
[[ "$ip_ready" -eq 0 || -s "$TEMP_DIR/china_ip6.txt" ]] || ip_ready=0
if [[ "$ip_ready" -eq 1 ]] && ! awk '
	BEGIN {
		print "{\"version\":5,\"rules\":[{\"ip_cidr\":["
		first = 1
	}
	NF {
		printf "%s\"%s\"", first ? "" : ",", $0
		first = 0
	}
	END { print "]}]}" }
' "$TEMP_DIR/china_ip4.txt" "$TEMP_DIR/china_ip6.txt" > "$TEMP_DIR/geoip_cn.json"; then
	ip_ready=0
fi
[[ "$ip_ready" -eq 0 || -s "$TEMP_DIR/geoip_cn.json" ]] || ip_ready=0
if [[ "$ip_ready" -eq 1 ]]; then
	printf '%s\n' "$ip_version" > "$TEMP_DIR/china_ip4.ver"
	printf '%s\n' "$ip_version" > "$TEMP_DIR/china_ip6.ver"
	ip_data_changed=1
	if cmp -s "$TEMP_DIR/china_ip4.txt" "$RESOURCES_DIR/china_ip4.txt" && \
	   cmp -s "$TEMP_DIR/china_ip6.txt" "$RESOURCES_DIR/china_ip6.txt"; then
		ip_data_changed=0
	fi
	for file in china_ip4.txt china_ip4.ver china_ip6.txt china_ip6.ver geoip_cn.json; do
		install -m 0644 "$TEMP_DIR/$file" "$RESOURCES_DIR/$file" || ip_ready=0
	done
fi
if [[ "$ip_ready" -eq 1 ]]; then
	if [[ "$ip_data_changed" -eq 0 ]]; then
		echo "HomeProxy resources: china_ip $ip_version (CIDR data unchanged)"
	else
		echo "HomeProxy resources: china_ip $ip_version (CIDR data updated)"
	fi
else
	warn "Failed to update HomeProxy IP resources; continuing."
	update_failed=1
fi

geosite_ready=1
geosite_version="$(fetch_release_version "$GEOSITE_VERSION_URL")" || geosite_ready=0
if [[ "$geosite_ready" -eq 1 ]] && \
	download "${GEOSITE_SOURCE}?v=${geosite_version}" "$TEMP_DIR/geosite_cn.srs" && \
	printf '%s\n' "$geosite_version" > "$TEMP_DIR/geosite_cn.ver" && \
	install -m 0644 "$TEMP_DIR/geosite_cn.srs" "$RESOURCES_DIR/geosite_cn.srs" && \
	install -m 0644 "$TEMP_DIR/geosite_cn.ver" "$RESOURCES_DIR/geosite_cn.ver"; then
	echo "HomeProxy resources: geosite_cn $geosite_version"
else
	warn "Failed to update HomeProxy geosite; continuing."
	update_failed=1
fi

dashboard_ready=1
dashboard_version="$(fetch_dashboard_version)" || dashboard_ready=0
if [[ "$dashboard_ready" -eq 1 ]] && \
	! download "${DASHBOARD_SOURCE}?v=${dashboard_version}" "$TEMP_DIR/dashboard.zip"; then
	dashboard_ready=0
fi
if [[ "$dashboard_ready" -eq 1 ]] && ! unzip -q "$TEMP_DIR/dashboard.zip" -d "$TEMP_DIR/dashboard"; then
	dashboard_ready=0
fi
dashboard_source_dir=""
if [[ "$dashboard_ready" -eq 1 ]]; then
	for dashboard_index in "$TEMP_DIR/dashboard/index.html" "$TEMP_DIR"/dashboard/*/index.html; do
		if [[ -f "$dashboard_index" ]]; then
			dashboard_source_dir="${dashboard_index%/index.html}"
			break
		fi
	done
	[[ -f "$dashboard_source_dir/index.html" ]] || dashboard_ready=0
fi
if [[ "$dashboard_ready" -eq 1 ]]; then
	rm -rf -- "$DASHBOARD_STAGE"
	if mkdir -p -- "$DASHBOARD_STAGE" && \
		cp -a -- "$dashboard_source_dir/." "$DASHBOARD_STAGE/" && \
		printf '%s\n' "$dashboard_version" > "$DASHBOARD_STAGE/dashboard.ver"; then
		rm -f -- "$DASHBOARD_STAGE/.etag"
		chmod -R a+rX "$DASHBOARD_STAGE"
	else
		dashboard_ready=0
	fi
fi
if [[ "$dashboard_ready" -eq 1 ]]; then
	rm -rf -- "$DASHBOARD_DIR"
	if mv -- "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
		echo "HomeProxy dashboard: $dashboard_version"
	else
		dashboard_ready=0
	fi
fi
if [[ "$dashboard_ready" -ne 1 ]]; then
	warn "Failed to update HomeProxy dashboard; continuing."
	update_failed=1
fi

resource_version="${geosite_version:-${ip_version:-${dashboard_version:-unknown}}}"
set_output version "$resource_version"
set_output partial_failure "$update_failed"
if [[ "$update_failed" -ne 0 ]]; then
	warn "HomeProxy resource update completed with partial failures."
fi
