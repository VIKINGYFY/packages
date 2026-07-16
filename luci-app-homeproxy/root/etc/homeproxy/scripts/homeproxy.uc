/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

import { popen } from 'fs';
import { urldecode_params } from 'luci.http';

/* Global variables start */
export const HP_DIR = '/etc/homeproxy';
export const RUN_DIR = '/var/run/homeproxy';
/* Global variables end */

/* Utilities start */
/* Kanged from luci-app-commands */
export function shellQuote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
};

export function isBinary(str) {
	for (let off = 0, byte = ord(str); off < length(str); byte = ord(str, ++off))
		if (byte <= 8 || (byte >= 14 && byte <= 31))
			return true;

	return false;
};

export function getTime(epoch) {
	const local_time = localtime(epoch);
	return replace(replace(sprintf(
		'%d-%2d-%2d@%2d:%2d:%2d',
		local_time.year,
		local_time.mon,
		local_time.mday,
		local_time.hour,
		local_time.min,
		local_time.sec
	), ' ', '0'), '@', ' ');

};

export function wGET(url, ua, proxyUrl) {
	if (!url || type(url) !== 'string')
		return null;

	if (!ua)
		ua = 'v2rayN/7.23.4';

	const maxSize = 4 * 1024 * 1024;
	const proxyArg = proxyUrl ? `--proxy ${shellQuote(proxyUrl)} ` : '';
	const outfd = popen(
		`/usr/bin/curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 ` +
		`--connect-timeout 10 --max-time 60 ` +
		`--max-filesize ${maxSize} ${proxyArg}-A ${shellQuote(ua)} ${shellQuote(url)} ` +
		`2>/dev/null`
	);
	if (!outfd)
		return null;

	let chunks = [], total = 0, oversized = false;
	while (true) {
		const chunk = outfd.read(64 * 1024);
		if (chunk === null || chunk === '')
			break;
		total += length(chunk);
		if (total > maxSize) {
			oversized = true;
			break;
		}
		push(chunks, chunk);
	}
	const exitcode = outfd.close();
	const output = join('', chunks);

	if (exitcode !== 0 || oversized || isBinary(output))
		return null;

	return trim(output);
};
/* Utilities end */

/* String helper start */
export function isEmpty(res) {
	return !res || res === 'nil' || (type(res) in ['array', 'object'] && length(res) === 0);
};

export function hasForceProxyRules(uci, config, proxyDomainList) {
	if (!isEmpty(proxyDomainList))
		return true;

	for (let option in [
		'lan_proxy_ipv4_ips', 'lan_proxy_mac_addrs',
		'wan_proxy_ipv4_ips', 'wan_proxy_ipv6_ips'
	])
		if (!isEmpty(uci.get(config, 'control', option)))
			return true;

	return false;
};

export function strToBool(str) {
	return (str === '1') || null;
};

export function strToInt(str) {
	return !isEmpty(str) ? (int(str) || null) : null;
};

export function strToTime(str) {
	return !isEmpty(str) ? (str + 's') : null;
};

function strListToInts(value) {
	if (type(value) !== 'array' || isEmpty(value))
		return null;

	return map(value, (item) => int(item));
};

export function renderEndpoint(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	return {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		address: node.wireguard_local_address,
		mtu: strToInt(node.wireguard_mtu),
		private_key: node.wireguard_private_key,
		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: strToInt(node.port),
				allowed_ips: [
					'0.0.0.0/0',
					'::/0'
				],
				persistent_keepalive_interval: strToInt(node.wireguard_persistent_keepalive_interval),
				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: strListToInts(node.wireguard_reserved)
			}
		] : null,
		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};
};

export function renderV2RayTransport(node, server_mode) {
	if (type(node) !== 'object' || isEmpty(node.transport))
		return null;

	switch (node.transport) {
	case 'grpc':
		return {
			type: 'grpc',
			service_name: node.grpc_servicename,
			idle_timeout: strToTime(node.http_idle_timeout),
			ping_timeout: strToTime(node.http_ping_timeout),
			permit_without_stream: server_mode ? null : strToBool(node.grpc_permit_without_stream)
		};
	case 'http':
		return {
			type: 'http',
			host: node.http_host,
			path: node.http_path,
			method: node.http_method,
			idle_timeout: strToTime(node.http_idle_timeout),
			ping_timeout: server_mode ? null : strToTime(node.http_ping_timeout)
		};
	case 'httpupgrade':
		return {
			type: 'httpupgrade',
			host: node.httpupgrade_host,
			path: node.http_path
		};
	case 'quic':
		return { type: 'quic' };
	case 'ws':
		return {
			type: 'ws',
			path: node.ws_path,
			headers: node.ws_host ? { Host: node.ws_host } : null,
			max_early_data: strToInt(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header
		};
	default:
		return null;
	}
};

export function renderOutbound(node, routingMark) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const renderTLS = () => {
		if (node.tls !== '1' || !(node.type in [
			'anytls', 'http', 'hysteria', 'hysteria2', 'shadowtls',
			'trojan', 'tuic', 'vless', 'vmess'
		]))
			return null;

		const tls_utls_value = (node.type === 'anytls' && isEmpty(node.tls_utls)) ? 'chrome' : node.tls_utls;
		return {
			enabled: true,
			server_name: node.tls_sni,
			insecure: strToBool(node.tls_insecure),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,
			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config: node.tls_ech_config,
				config_path: node.tls_ech_config_path
			} : null,
			utls: !isEmpty(tls_utls_value) ? {
				enabled: true,
				fingerprint: tls_utls_value
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		};
	};

	const renderMultiplex = () => {
		if (node.multiplex !== '1' || !(node.type in ['shadowsocks', 'trojan', 'vless', 'vmess']))
			return null;
		return {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: strToBool(node.multiplex_padding),
			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(node.multiplex_brutal_up),
				down_mbps: strToInt(node.multiplex_brutal_down)
			} : null
		};
	};

	const outbound = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		routing_mark: strToInt(routingMark),
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	if (node.type !== 'direct') {
		outbound.server = node.address;
		outbound.server_port = strToInt(node.port);
	}

	switch (node.type) {
	case 'anytls':
		outbound.password = node.password;
		outbound.idle_session_check_interval = strToTime(node.anytls_idle_session_check_interval);
		outbound.idle_session_timeout = strToTime(node.anytls_idle_session_timeout);
		outbound.min_idle_session = strToInt(node.anytls_min_idle_session);
		break;
	case 'http':
		outbound.username = node.username;
		outbound.password = node.password;
		break;
	case 'hysteria':
	case 'hysteria2':
		outbound.server_ports = node.hysteria_hopping_port;
		outbound.hop_interval = strToTime(node.hysteria_hop_interval);
		outbound.up_mbps = strToInt(node.hysteria_up_mbps);
		outbound.down_mbps = strToInt(node.hysteria_down_mbps);
		outbound.network = node.hysteria_network;
		outbound.stream_receive_window = !isEmpty(node.hysteria_stream_receive_window) ? `${node.hysteria_stream_receive_window} B` : null;
		outbound.connection_receive_window = !isEmpty(node.hysteria_connection_receive_window) ? `${node.hysteria_connection_receive_window} B` : null;
		outbound.disable_path_mtu_discovery = strToBool(node.hysteria_disable_path_mtu_discovery);
		outbound.obfs = (node.type === 'hysteria2' && node.hysteria_obfs_type) ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password;
		if (node.type === 'hysteria') {
			outbound.auth = (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null;
			outbound.auth_str = (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null;
		} else
			outbound.password = node.password;
		break;
	case 'shadowsocks':
		outbound.method = node.shadowsocks_encrypt_method;
		outbound.password = node.password;
		outbound.plugin = node.shadowsocks_plugin;
		outbound.plugin_opts = node.shadowsocks_plugin_opts;
		break;
	case 'shadowtls':
		outbound.password = node.password;
		outbound.version = strToInt(node.shadowtls_version);
		break;
	case 'socks':
		outbound.username = node.username;
		outbound.password = node.password;
		outbound.version = node.socks_version;
		outbound.udp_over_tcp = (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.udp_over_tcp_version)
		} : null;
		break;
	case 'ssh':
		outbound.user = node.username;
		outbound.password = node.password;
		outbound.client_version = node.ssh_client_version;
		outbound.host_key = node.ssh_host_key;
		outbound.host_key_algorithms = node.ssh_host_key_algo;
		outbound.private_key = node.ssh_priv_key;
		outbound.private_key_passphrase = node.ssh_priv_key_pp;
		break;
	case 'trojan':
		outbound.password = node.password;
		outbound.transport = renderV2RayTransport(node);
		break;
	case 'tuic':
		outbound.uuid = node.uuid;
		outbound.password = node.password;
		outbound.congestion_control = node.tuic_congestion_control;
		outbound.udp_relay_mode = node.tuic_udp_relay_mode;
		outbound.udp_over_stream = strToBool(node.tuic_udp_over_stream);
		outbound.zero_rtt_handshake = strToBool(node.tuic_enable_zero_rtt);
		outbound.heartbeat = strToTime(node.tuic_heartbeat);
		break;
	case 'vless':
		outbound.uuid = node.uuid;
		outbound.flow = node.vless_flow;
		outbound.packet_encoding = node.packet_encoding;
		outbound.transport = renderV2RayTransport(node);
		break;
	case 'vmess':
		outbound.uuid = node.uuid;
		outbound.alter_id = strToInt(node.vmess_alterid);
		outbound.security = node.vmess_encrypt;
		outbound.global_padding = strToBool(node.vmess_global_padding);
		outbound.authenticated_length = strToBool(node.vmess_authenticated_length);
		outbound.packet_encoding = node.packet_encoding;
		outbound.transport = renderV2RayTransport(node);
		break;
	}

	outbound.tls = renderTLS();
	outbound.multiplex = renderMultiplex();
	return outbound;
};

export function removeBlankAttrs(res) {
	let content;

	if (type(res) === 'object') {
		content = {};
		map(keys(res), (k) => {
			if (type(res[k]) in ['array', 'object'])
				content[k] = removeBlankAttrs(res[k]);
			else if (res[k] !== null && res[k] !== '')
				content[k] = res[k];
		});
	} else if (type(res) === 'array') {
		content = [];
		map(res, (k, i) => {
			if (type(k) in ['array', 'object'])
				push(content, removeBlankAttrs(k));
			else if (k !== null && k !== '')
				push(content, k);
		});
	} else
		return res;

	return content;
};

export function validateHostname(hostname) {
	return (match(hostname, /^[a-zA-Z0-9_]+$/) != null ||
		(match(hostname, /^[a-zA-Z0-9_][a-zA-Z0-9_%-.]*[a-zA-Z0-9]$/) &&
			match(hostname, /[^0-9.]/)));
};

export function validation(datatype, data) {
	if (!datatype || !data)
		return null;

	const ret = system(`/sbin/validate_data ${shellQuote(datatype)} ${shellQuote(data)} 2>/dev/null`);
	return (ret === 0);
};
/* String helper end */

/* String parser start */
export function decodeBase64Str(str) {
	if (isEmpty(str))
		return null;

	str = trim(str);
	str = replace(str, '_', '/');
	str = replace(str, '-', '+');

	const padding = length(str) % 4;
	if (padding)
		str = str + substr('====', padding);

	return b64dec(str);
};

export function parseURL(url) {
	if (type(url) !== 'string')
		return null;

	const services = {
		http: '80',
		https: '443'
	};

	const objurl = {};

	objurl.href = url;

	url = replace(url, /#(.+)$/, (_, val) => {
		objurl.hash = val;
		return '';
	});

	url = replace(url, /^(\w[A-Za-z0-9\+\-\.]+):/, (_, val) => {
		objurl.protocol = val;
		return '';
	});

	url = replace(url, /\?(.+)/, (_, val) => {
		objurl.search = val;
		objurl.searchParams = urldecode_params(val);
		return '';
	});

	url = replace(url, /^\/\/([^\/]+)/, (_, val) => {
		val = replace(val, /^([^@]+)@/, (_, val) => {
			objurl.userinfo = val;
			return '';
		});

		val = replace(val, /:(\d+)$/, (_, val) => {
			objurl.port = val;
			return '';
		});

		if (validation('ip4addr', val) ||
		    validation('ip6addr', replace(val, /\[|\]/g, '')) ||
		    validation('hostname', val))
			objurl.hostname = val;

		return '';
	});

	objurl.pathname = url || '/';

	if (!objurl.protocol || !objurl.hostname)
		return null;

	if (objurl.userinfo) {
		objurl.userinfo = replace(objurl.userinfo, /:(.+)$/, (_, val) => {
			objurl.password = val;
			return '';
		});

		if (match(objurl.userinfo, /^[A-Za-z0-9\+\-\_\.]+$/)) {
			objurl.username = objurl.userinfo;
			delete objurl.userinfo;
		} else {
			delete objurl.userinfo;
			delete objurl.password;
		}
	};

	if (!objurl.port)
		objurl.port = services[objurl.protocol];

	objurl.host = objurl.hostname + (objurl.port ? `:${objurl.port}` : '');
	objurl.origin = `${objurl.protocol}://${objurl.host}`;

	return objurl;
};
/* String parser end */
