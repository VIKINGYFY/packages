# Shared service and hotplug integration for the installed firewall variant.

upnpd_load_backend() {
	local backend
	read -r backend < /usr/share/miniupnpd/backend || return 1
	case "$backend" in
		iptables) FW=fw3 ;;
		nftables) FW=fw4 ;;
		*) return 1 ;;
	esac
}

upnpd_resolve_interface() {
	local result="$1" iface="$2" zone="$3" family="$4" device
	unset "$result"
	if [ -n "$iface" ]; then
		network_get_device "$result" "$iface"
		return
	fi

	if [ "$family" = 6 ]; then
		network_find_wan6 iface
	else
		network_find_wan iface
	fi
	if [ -n "$iface" ] && network_get_device device "$iface"; then
		if [ -z "$zone" ] || $FW -q zone "$zone" "$device" >/dev/null 2>&1; then
			export -n "$result=$device"
			return 0
		fi
	fi

	[ -n "$zone" ] || return 1
	for device in $($FW -q zone "$zone" 2>/dev/null); do
		if ip -"$family" address show dev "$device" scope global 2>/dev/null | grep -q "inet"; then
			export -n "$result=$device"
			return 0
		fi
	done
	return 1
}

upnpd_queue_reload() {
	ubus call service event '{"type":"miniupnpd.reload","data":{}}' >/dev/null
}

upnpd_wait_for_exit() {
	local attempt pid running
	attempt=0
	while [ "$attempt" -lt 10 ]; do
		running=0
		for pid in "$@"; do
			kill -0 "$pid" 2>/dev/null && running=1
		done
		[ "$running" = 0 ] && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

upnpd_flush_firewall() {
	if [ "$FW" = fw4 ]; then
		local chain
		for chain in upnp_forward upnp_prerouting upnp_postrouting; do
			nft flush chain inet fw4 "$chain" 2>/dev/null
		done
	else
		iptables -w 1 -t nat -F MINIUPNPD 2>/dev/null
		iptables -w 1 -t nat -F MINIUPNPD-POSTROUTING 2>/dev/null
		iptables -w 1 -t filter -F MINIUPNPD 2>/dev/null
		[ ! -x /usr/sbin/ip6tables ] || ip6tables -w 1 -t filter -F MINIUPNPD 2>/dev/null
	fi
	return 0
}

upnpd_firewall_ready() {
	if [ "$FW" = fw4 ]; then
		local chain
		for chain in upnp_forward upnp_prerouting upnp_postrouting; do
			nft list chain inet fw4 "$chain" >/dev/null 2>&1 || return 1
		done
	else
		iptables -w 1 -t filter -S MINIUPNPD >/dev/null 2>&1 &&
		iptables -w 1 -t nat -S MINIUPNPD >/dev/null 2>&1 &&
		iptables -w 1 -t nat -S MINIUPNPD-POSTROUTING >/dev/null 2>&1
	fi
}

upnpd_prepare_firewall() {
	upnpd_firewall_ready && return 0
	$FW reload || return 1
	upnpd_firewall_ready
}
