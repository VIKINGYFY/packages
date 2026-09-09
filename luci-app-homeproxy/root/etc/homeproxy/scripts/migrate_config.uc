#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2025 ImmortalWrt.org
 */

'use strict';

import { unlink } from 'fs';
import { cursor } from 'uci';
import {
	isEmpty, normalizeList, reconcileUrltestNodes, synchronizeNodeLabels, HP_DIR
} from 'homeproxy';

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
const stockCommonPort = '22,53,80,143,443,465,587,853,873,993,995,5222,8080,8443,9418';
const updatedCommonPort = '20,21,22,25,53,80,110,119,123,143,389,443,465,514,563,587,636,853,873,989,990,993,995,1194,1883,3306,3389,5222,5432,5671,5672,5900,6379,6443,6514,8080,8443,8883,9418';

function onlyContains(left, right) {
	const values = normalizeList(left);
	return length(values) > 0 && length(filter(values, (value) => index(right, value) === -1)) === 0;
}

function setDefault(section, option, value) {
	if (uci.get(uciconfig, section, option) === null)
		uci.set(uciconfig, section, option, value);
}

function deleteOptions(section, options) {
	for (let option in options)
		if (uci.get(uciconfig, section, option) !== null)
			uci.delete(uciconfig, section, option);
}

function deleteSections(sectionType) {
	const sections = [];
	uci.foreach(uciconfig, sectionType, (section) => push(sections, section['.name']));
	for (let section in sections)
		uci.delete(uciconfig, section);
}

function migrateOption(section, oldOption, newOption) {
	const oldValue = uci.get(uciconfig, section, oldOption);
	if (oldValue === null)
		return;
	if (uci.get(uciconfig, section, newOption) === null)
		uci.set(uciconfig, section, newOption, oldValue);
	uci.delete(uciconfig, section, oldOption);
}

function moveOption(sourceSection, sourceOption, targetSection, targetOption) {
	const sourceValue = uci.get(uciconfig, sourceSection, sourceOption);
	if (sourceValue === null)
		return;
	if (uci.get(uciconfig, targetSection, targetOption) === null)
		uci.set(uciconfig, targetSection, targetOption, sourceValue);
	uci.delete(uciconfig, sourceSection, sourceOption);
}

function mergeListOption(section, sourceOption, targetOption) {
	const source = normalizeList(uci.get(uciconfig, section, sourceOption));
	const target = normalizeList(uci.get(uciconfig, section, targetOption));
	if (length(source))
		uci.set(uciconfig, section, targetOption, uniq([...target, ...source]));
	if (uci.get(uciconfig, section, sourceOption) !== null)
		uci.delete(uciconfig, section, sourceOption);
}

const commonPort = uci.get(uciconfig, 'infra', 'common_port');
if (commonPort === stockCommonPort)
	uci.set(uciconfig, 'infra', 'common_port', updatedCommonPort);
else
	setDefault('infra', 'common_port', updatedCommonPort);

/* Only migrate nodes written before this schema marker was recorded. */
const subscriptionNodeMigration = '1';
const subscriptionNodeMigrationOption = 'subscription_node_migration';
const subscriptionNodeMigrationState = uci.get(
	uciconfig, 'migration', subscriptionNodeMigrationOption
);
if (subscriptionNodeMigrationState !== subscriptionNodeMigration) {
	const subscriptionNodes = [];
	uci.foreach(uciconfig, 'node', (section) => {
		if (section.grouphash)
			push(subscriptionNodes, section['.name']);
	});
	for (let node in subscriptionNodes)
		uci.delete(uciconfig, node);

	if (uci.get(uciconfig, 'migration') === null)
		uci.set(uciconfig, 'migration', 'homeproxy');
	uci.set(
		uciconfig, 'migration', subscriptionNodeMigrationOption,
		subscriptionNodeMigration
	);
}

synchronizeNodeLabels(uci, uciconfig);

/* Keep only the supported routing modes. */
if (!(uci.get(uciconfig, 'config', 'routing_mode') in ['bypass_mainland_china', 'global']))
	uci.set(uciconfig, 'config', 'routing_mode', 'bypass_mainland_china');
deleteOptions('config', [
	'proxy_mode',
	'main_udp_node', 'main_udp_urltest_nodes',
	'main_udp_urltest_interval', 'main_udp_urltest_tolerance',
	'github_token', 'dashboard_download_url'
]);

deleteOptions('infra', [
	'china_dns_port', 'redirect_port', 'tun_mark', 'tun_gso',
	'tproxy_port', 'table_mark', 'self_mark', 'tproxy_mark',
	'sniff_override', 'github_token'
]);

if (uci.get(uciconfig, 'config', 'routing_port') === 'all')
	uci.delete(uciconfig, 'config', 'routing_port');

moveOption('routing', 'tcpip_stack', 'config', 'tcpip_stack');

for (let pair in [
	['lan_gaming_mode_ipv4_ips', 'lan_proxy_ipv4_ips'],
	['lan_gaming_mode_mac_addrs', 'lan_proxy_mac_addrs'],
	['lan_global_proxy_ipv4_ips', 'lan_proxy_ipv4_ips'],
	['lan_global_proxy_mac_addrs', 'lan_proxy_mac_addrs']
])
	mergeListOption('control', pair[0], pair[1]);

deleteOptions('control', [
	'lan_proxy_mode', 'lan_direct_ipv6_ips', 'lan_proxy_ipv6_ips',
	'lan_global_proxy_ipv6_ips', 'lan_gaming_mode_ipv6_ips',
	'direct_domain_list_checksum', 'proxy_domain_list_checksum'
]);

if (isEmpty(uci.get(uciconfig, 'diversion')))
	uci.set(uciconfig, 'diversion', 'homeproxy');

for (let sectionType in ['routing_node', 'routing_rule', 'dns_server', 'dns_rule', 'ruleset'])
	deleteSections(sectionType);
for (let section in ['routing', 'dns'])
	if (uci.get(uciconfig, section) !== null)
		uci.delete(uciconfig, section);

uci.foreach(uciconfig, 'node', (section) => {
	for (let pair in [
		['hysteria_recv_window_conn', 'hysteria_stream_receive_window'],
		['hysteria_revc_window', 'hysteria_connection_receive_window'],
		['hysteria_disable_mtu_discovery', 'hysteria_disable_path_mtu_discovery']
	])
		migrateOption(section['.name'], pair[0], pair[1]);
	deleteOptions(section['.name'], ['hysteria_protocol']);
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
	deleteOptions(section['.name'], ['hysteria_protocol']);
});

/* These Telegram ranges were redundant after the old routing modes were removed. */
if (onlyContains(uci.get(uciconfig, 'control', 'wan_proxy_ipv4_ips'), stockWanProxyIPv4))
	uci.delete(uciconfig, 'control', 'wan_proxy_ipv4_ips');
if (onlyContains(uci.get(uciconfig, 'control', 'wan_proxy_ipv6_ips'), stockWanProxyIPv6))
	uci.delete(uciconfig, 'control', 'wan_proxy_ipv6_ips');

deleteOptions('subscription', ['latency_test_mode']);

const subscriptionUserAgent = uci.get(uciconfig, 'subscription', 'user_agent');
if (subscriptionUserAgent === 'v2rayN/7.23.4' ||
	subscriptionUserAgent === 'sing-box/1.14.0-beta.2')
	uci.set(uciconfig, 'subscription', 'user_agent', 'homeproxy');

setDefault('infra', 'ntp_server', 'nil');
if (isEmpty(uci.get(uciconfig, 'infra', 'udp_timeout')))
	uci.set(uciconfig, 'infra', 'udp_timeout', '300');
setDefault('config', 'main_urltest_interval', '120');
setDefault('config', 'main_urltest_tolerance', '60');
setDefault('config', 'main_urltest_interrupt_exist_connections', '0');
setDefault('config', 'log_level', 'warn');
setDefault('config', 'tcpip_stack', 'mixed');
setDefault('control', 'lan_whitelist_mode', '0');
setDefault('server', 'log_level', 'warn');

reconcileUrltestNodes(uci, uciconfig);

const mainNode = uci.get(uciconfig, 'config', 'main_node') || 'nil';
if (mainNode !== 'nil' && mainNode !== 'urltest' &&
	uci.get(uciconfig, mainNode) !== 'node')
	uci.set(uciconfig, 'config', 'main_node', uci.get_first(uciconfig, 'node') || 'nil');

for (let file in ['china_list.txt', 'china_list.ver', 'gfw_list.txt', 'gfw_list.ver'])
	unlink(`${HP_DIR}/resources/${file}`);

if (!isEmpty(uci.changes(uciconfig)) && uci.commit(uciconfig) !== true)
	exit(1);
