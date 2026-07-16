#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2025 ImmortalWrt.org
 */

'use strict';

import { cursor } from 'uci';
import { isEmpty } from 'homeproxy';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

const stockWanProxyIPv4 = [
	'91.105.192.0/23', '91.108.4.0/22', '91.108.8.0/21', '91.108.16.0/21',
	'91.108.56.0/22', '95.161.64.0/20', '149.154.160.0/20', '185.76.151.0/24'
];
const stockWanProxyIPv6 = [
	'2001:67c:4e8::/48', '2001:b28:f23c::/47',
	'2001:b28:f23f::/48', '2a0a:f280::/32'
];

function normalizeList(value) {
	if (isEmpty(value))
		return [];
	return (type(value) === 'array') ? value : [value];
}

function onlyContains(left, right) {
	const values = normalizeList(left);
	return length(values) > 0 && length(filter(values, (value) => index(right, value) === -1)) === 0;
}

function setDefault(section, option, value) {
	if (uci.get(uciconfig, section, option) === null)
		uci.set(uciconfig, section, option, value);
}

function migrateOption(section, oldOption, newOption) {
	const oldValue = uci.get(uciconfig, section, oldOption);
	if (oldValue === null)
		return;
	if (uci.get(uciconfig, section, newOption) === null)
		uci.set(uciconfig, section, newOption, oldValue);
	uci.delete(uciconfig, section, oldOption);
}

function mergeListOption(section, sourceOption, targetOption) {
	const source = normalizeList(uci.get(uciconfig, section, sourceOption));
	const target = normalizeList(uci.get(uciconfig, section, targetOption));
	if (length(source))
		uci.set(uciconfig, section, targetOption, uniq([...target, ...source]));
	if (uci.get(uciconfig, section, sourceOption) !== null)
		uci.delete(uciconfig, section, sourceOption);
}

/* Keep only the modes implemented by the 1.14 configuration generator. */
if (!(uci.get(uciconfig, 'config', 'routing_mode') in ['bypass_mainland_china', 'custom', 'global']))
	uci.set(uciconfig, 'config', 'routing_mode', 'bypass_mainland_china');
if (!(uci.get(uciconfig, 'config', 'proxy_mode') in ['tun', 'tproxy']))
	uci.set(uciconfig, 'config', 'proxy_mode', 'tun');

for (let option in [
	'main_udp_node', 'main_udp_urltest_nodes',
	'main_udp_urltest_interval', 'main_udp_urltest_tolerance',
	'github_token', 'dashboard_download_url'
])
	if (uci.get(uciconfig, 'config', option) !== null)
		uci.delete(uciconfig, 'config', option);

for (let option in [
	'china_dns_port', 'redirect_port', 'tun_mark', 'tun_gso',
	'sniff_override', 'github_token'
])
	if (uci.get(uciconfig, 'infra', option) !== null)
		uci.delete(uciconfig, 'infra', option);

for (let option in ['endpoint_independent_nat', 'sniff_override'])
	if (uci.get(uciconfig, 'routing', option) !== null)
		uci.delete(uciconfig, 'routing', option);

for (let option in ['independent_cache', 'cache_file_store_rdrc', 'cache_file_rdrc_timeout'])
	if (uci.get(uciconfig, 'dns', option) !== null)
		uci.delete(uciconfig, 'dns', option);

if (uci.get(uciconfig, 'config', 'routing_port') === 'all')
	uci.delete(uciconfig, 'config', 'routing_port');
if (uci.get(uciconfig, 'routing', 'default_outbound') === 'block-out')
	uci.set(uciconfig, 'routing', 'default_outbound', 'reject');

for (let pair in [
	['lan_gaming_mode_ipv4_ips', 'lan_proxy_ipv4_ips'],
	['lan_gaming_mode_mac_addrs', 'lan_proxy_mac_addrs'],
	['lan_global_proxy_ipv4_ips', 'lan_proxy_ipv4_ips'],
	['lan_global_proxy_mac_addrs', 'lan_proxy_mac_addrs']
])
	mergeListOption('control', pair[0], pair[1]);

for (let option in [
	'lan_proxy_mode', 'lan_direct_ipv6_ips', 'lan_proxy_ipv6_ips',
	'lan_global_proxy_ipv6_ips', 'lan_gaming_mode_ipv6_ips'
])
	if (uci.get(uciconfig, 'control', option) !== null)
		uci.delete(uciconfig, 'control', option);

uci.foreach(uciconfig, 'node', (section) => {
	for (let pair in [
		['hysteria_recv_window_conn', 'hysteria_stream_receive_window'],
		['hysteria_revc_window', 'hysteria_connection_receive_window'],
		['hysteria_disable_mtu_discovery', 'hysteria_disable_path_mtu_discovery']
	])
		migrateOption(section['.name'], pair[0], pair[1]);
	if (uci.get(uciconfig, section['.name'], 'hysteria_protocol') !== null)
		uci.delete(uciconfig, section['.name'], 'hysteria_protocol');
});

uci.foreach(uciconfig, 'server', (section) => {
	for (let pair in [
		['hysteria_recv_window_conn', 'hysteria_stream_receive_window'],
		['hysteria_recv_window_client', 'hysteria_connection_receive_window'],
		['hysteria_revc_window_client', 'hysteria_connection_receive_window'],
		['hysteria_max_conn_client', 'hysteria_max_concurrent_streams'],
		['hysteria_disable_mtu_discovery', 'hysteria_disable_path_mtu_discovery']
	])
		migrateOption(section['.name'], pair[0], pair[1]);
	if (uci.get(uciconfig, section['.name'], 'hysteria_protocol') !== null)
		uci.delete(uciconfig, section['.name'], 'hysteria_protocol');
});

/* These Telegram ranges were redundant after the old routing modes were removed. */
if (onlyContains(uci.get(uciconfig, 'control', 'wan_proxy_ipv4_ips'), stockWanProxyIPv4))
	uci.delete(uciconfig, 'control', 'wan_proxy_ipv4_ips');
if (onlyContains(uci.get(uciconfig, 'control', 'wan_proxy_ipv6_ips'), stockWanProxyIPv6))
	uci.delete(uciconfig, 'control', 'wan_proxy_ipv6_ips');

if (uci.get(uciconfig, 'subscription', 'latency_test_mode') !== null)
	uci.delete(uciconfig, 'subscription', 'latency_test_mode');

setDefault('infra', 'ntp_server', 'nil');
if (isEmpty(uci.get(uciconfig, 'infra', 'udp_timeout')))
	uci.set(uciconfig, 'infra', 'udp_timeout', '300');
setDefault('config', 'main_urltest_interval', '180');
setDefault('config', 'main_urltest_tolerance', '50');
setDefault('config', 'main_urltest_interrupt_exist_connections', '1');
setDefault('config', 'log_level', 'warn');
setDefault('routing', 'tcpip_stack', 'system');
if (isEmpty(uci.get(uciconfig, 'routing', 'udp_timeout')))
	uci.set(uciconfig, 'routing', 'udp_timeout', '300');
setDefault('routing', 'bypass_cn_traffic', '0');
setDefault('routing', 'default_outbound', 'nil');
setDefault('routing', 'default_outbound_dns', 'default-dns');
setDefault('dns', 'default_strategy', 'prefer_ipv4');
setDefault('dns', 'default_server', 'default-dns');
setDefault('dns', 'disable_cache', '0');
setDefault('dns', 'disable_cache_expire', '0');
setDefault('dns', 'cache_file_store_dns', '0');
setDefault('server', 'log_level', 'warn');

if (uci.get(uciconfig, 'migration'))
	uci.delete(uciconfig, 'migration');

system('rm -f "/etc/homeproxy/resources/china_list.txt" "/etc/homeproxy/resources/china_list.ver" "/etc/homeproxy/resources/gfw_list.txt" "/etc/homeproxy/resources/gfw_list.ver"');

if (!isEmpty(uci.changes(uciconfig)) && uci.commit(uciconfig) !== true)
	exit(1);
