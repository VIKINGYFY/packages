#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	createNodeLabelRegistry, filterExistingNodes, hasForceProxyRules, isEmpty,
	normalizeList, parseURL,
	reserveUniqueLabel, strToBool, strToInt, strToTime,
	removeBlankAttrs, renderEndpoint, renderOutbound, validation, HP_DIR, RUN_DIR
} from 'homeproxy';

const ubus = connect();

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      ucicontrol = 'control';

const ucinode = 'node';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';

if (!(routing_mode in ['bypass_mainland_china', 'global']))
	die('Unsupported routing mode. Select bypass_mainland_china or global.');

const outbound_tags = createNodeLabelRegistry();
const node_outbound_tags = {};

uci.foreach(uciconfig, ucinode, (cfg) => {
	node_outbound_tags[cfg['.name']] = reserveUniqueLabel(
		outbound_tags,
		cfg.label, `cfg-${cfg['.name']}-out`
	);
});
function get_node_outbound_tag(section_id) {
	return node_outbound_tags[section_id] || `cfg-${section_id}-out`;
}

function render_domain_rules(domains) {
	let suffixes = [], keywords = [];

	for (let domain in domains) {
		domain = trim(domain);
		if (!domain)
			continue;

		push(match(domain, /\./) ? suffixes : keywords, domain);
	}

	let rules = [];
	if (length(suffixes))
		push(rules, { domain_suffix: suffixes });
	if (length(keywords))
		push(rules, { domain_keyword: keywords });

	return rules;
}

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode === 'global') ? '9.9.9.9' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

const main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

let dns_server = uci.get(uciconfig, ucimain, 'dns_server');
if (isEmpty(dns_server) || dns_server === 'wan')
	dns_server = wan_dns;

let china_dns_server;
if (routing_mode === 'bypass_mainland_china') {
	china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
	if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
		china_dns_server = wan_dns;
}
const dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

let direct_domain_list = [], proxy_domain_list = [];
const direct_domain_content = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
if (direct_domain_content)
	direct_domain_list = split(direct_domain_content, /[\r\n]/);

if (routing_mode === 'bypass_mainland_china') {
	const proxy_domain_content = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
	if (proxy_domain_content)
		proxy_domain_list = split(proxy_domain_content, /[\r\n]/);
}

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'tun',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface'),
      listen_interfaces = normalizeList(uci.get(uciconfig, ucicontrol, 'listen_interfaces'));

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';
const clash_api_port = strToInt(uci.get(uciconfig, uciinfra, 'clash_api_port'));

let self_mark, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack, udp_timeout;
const tproxy_enabled = proxy_mode === 'tproxy';
const tun_enabled = proxy_mode === 'tun';

udp_timeout = uci.get(uciconfig, 'infra', 'udp_timeout');

if (tproxy_enabled)
	self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';

if (tproxy_enabled)
	tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';
if (tun_enabled) {
	tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
	tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
	tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
	tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
	tcpip_stack = uci.get(uciconfig, ucimain, 'tcpip_stack') || 'mixed';
}

const log_level = uci.get(uciconfig, ucimain, 'log_level') || 'warn';
const dashboard_path = HP_DIR + '/dashboard';
const dashboard_enabled = uci.get(uciconfig, ucimain, 'dashboard_enabled') === '1' &&
      !isEmpty(readfile(dashboard_path + '/index.html')),
      dashboard_port = strToInt(uci.get(uciconfig, ucimain, 'dashboard_port')),
      dashboard_secret = uci.get(uciconfig, ucimain, 'dashboard_secret');
const force_proxy_rules = hasForceProxyRules(uci, uciconfig, proxy_domain_list);
const fast_bypass_mainland = routing_mode === 'bypass_mainland_china' && !force_proxy_rules;
/* UCI config end */

/* Config helper start */
function merge_control_options(options) {
	let values = [];
	for (let option in options) {
		if (!option)
			continue;
		values = [...values, ...normalizeList(uci.get(uciconfig, ucicontrol, option))];
	}
	return values;
}

function normalize_cidrs(values) {
	return map(values, (value) => match(value, /\//) ? value : `${value}/${match(value, /:/) ? 128 : 32}`);
}

function source_match(ipv4_option, ipv6_option, mac_option) {
	const ips = normalize_cidrs(merge_control_options([ipv4_option, ipv6_option]));
	const macs = merge_control_options([mac_option]);
	let rules = [];

	if (length(ips))
		push(rules, { source_ip_cidr: ips });
	if (length(macs))
		push(rules, { source_mac_address: macs });

	if (length(rules) === 1)
		return rules[0];
	if (length(rules) > 1)
		return { type: 'logical', mode: 'or', rules };
	return null;
}

function destination_match(ipv4_option, ipv6_option) {
	const ips = normalize_cidrs(merge_control_options([ipv4_option, ipv6_option]));
	return length(ips) ? { ip_cidr: ips } : null;
}

function routing_port_match() {
	let value = uci.get(uciconfig, ucimain, 'routing_port');
	if (value === 'common')
		value = uci.get(uciconfig, uciinfra, 'common_port');
	if (isEmpty(value))
		return null;

	let ports = [], ranges = [], rules = [];
	for (let item in split(value, ',')) {
		item = trim(item);
		if (match(item, /-/))
			push(ranges, replace(item, '-', ':'));
		else if (item)
			push(ports, int(item));
	}
	if (length(ports))
		push(rules, { port: ports });
	if (length(ranges))
		push(rules, { port_range: ranges });

	if (length(rules) === 1)
		return rules[0];
	if (length(rules) > 1)
		return { type: 'logical', mode: 'or', rules };
	return null;
}

function push_route(rules, match_rule, outbound, invert) {
	if (!match_rule)
		return;
	push(rules, {
		...match_rule,
		invert: invert ? true : match_rule.invert,
		action: 'route',
		outbound
	});
}

function push_bypass(rules, match_rule) {
	if (!match_rule)
		return;
	push(rules, {
		...match_rule,
		action: 'bypass'
	});
}

function tun_match(match_rule) {
	if (!match_rule)
		return null;
	return {
		type: 'logical',
		mode: 'and',
		rules: [
			{ inbound: 'tun-in' },
			match_rule
		]
	};
}

function tun_unlisted_match(match_rule) {
	if (!match_rule)
		return { inbound: 'tun-in' };

	return tun_match({ ...match_rule, invert: !match_rule.invert });
}

function merge_matches(matches) {
	const rules = filter(matches, (rule) => rule);
	if (length(rules) === 1)
		return rules[0];
	if (length(rules) > 1)
		return { type: 'logical', mode: 'or', rules };
	return null;
}

function get_control_matches() {
	const included_ports = routing_port_match();
	const proxy_policy_mode = routing_mode === 'bypass_mainland_china';
	const lan_whitelist_mode = proxy_policy_mode &&
		uci.get(uciconfig, ucicontrol, 'lan_whitelist_mode') === '1';
	const proxy_source = proxy_policy_mode ?
		source_match('lan_proxy_ipv4_ips', null, 'lan_proxy_mac_addrs') : null;
	const auto_source = lan_whitelist_mode ?
		source_match('lan_auto_proxy_ipv4_ips', null, 'lan_auto_proxy_mac_addrs') : null;

	return {
		lan_whitelist_mode,
		direct_source: !lan_whitelist_mode ?
			source_match('lan_direct_ipv4_ips', null, 'lan_direct_mac_addrs') : null,
		proxy_source,
		auto_source,
		whitelist_source: lan_whitelist_mode ? merge_matches([auto_source, proxy_source]) : null,
		wan_proxy: proxy_policy_mode ? destination_match('wan_proxy_ipv4_ips', 'wan_proxy_ipv6_ips') : null,
		wan_direct: destination_match('wan_direct_ipv4_ips', 'wan_direct_ipv6_ips'),
		bypass_ports: included_ports ? { ...included_ports, invert: true } : null
	};
}

function add_control_pre_match_rules(rules, proxy_outbound) {
	const control = get_control_matches();

	if (control.lan_whitelist_mode)
		push_bypass(rules, tun_unlisted_match(control.whitelist_source));
	else
		push_bypass(rules, tun_match(control.direct_source));

	if (proxy_outbound) {
		push_route(rules, tun_match(control.proxy_source), proxy_outbound);
		push_route(rules, tun_match(control.wan_proxy), proxy_outbound);
	}
	push_bypass(rules, tun_match(control.wan_direct));
	push_bypass(rules, tun_match({ ip_is_private: true }));
	push_bypass(rules, tun_match(control.bypass_ports));
}

function add_control_rules(rules, proxy_outbound) {
	const control = get_control_matches();

	push_route(rules, control.direct_source, 'direct-out');

	if (proxy_outbound) {
		push_route(rules, control.proxy_source, proxy_outbound);
		push_route(rules, control.wan_proxy, proxy_outbound);
	}
	push_route(rules, control.wan_direct, 'direct-out');
	push(rules, { ip_is_private: true, action: 'route', outbound: 'direct-out' });
	push_route(rules, control.bypass_ports, 'direct-out');
}

function has_mac_control() {
	const lan_whitelist_mode = routing_mode === 'bypass_mainland_china' &&
		uci.get(uciconfig, ucicontrol, 'lan_whitelist_mode') === '1';
	return length(merge_control_options([
		!lan_whitelist_mode ? 'lan_direct_mac_addrs' : null,
		(routing_mode === 'bypass_mainland_china') ? 'lan_proxy_mac_addrs' : null,
		lan_whitelist_mode ? 'lan_auto_proxy_mac_addrs' : null
	])) > 0;
}

function add_mainland_rule_sets(rule_sets) {
	push(rule_sets, {
		type: 'local',
		tag: 'geoip-cn',
		format: 'source',
		path: HP_DIR + '/resources/geoip_cn.json'
	});
	push(rule_sets, {
		type: 'local',
		tag: 'geosite-cn',
		format: 'binary',
		path: HP_DIR + '/resources/geosite_cn.srs'
	});
}

function parse_dnsserver(server_addr, default_protocol) {
	if (isEmpty(server_addr))
		return null;

	if (!match(server_addr, /:\/\//))
		server_addr = (default_protocol || 'udp') + '://' + (validation('ip6addr', server_addr) ? `[${server_addr}]` : server_addr);
	server_addr = parseURL(server_addr);

	return {
		type: server_addr.protocol,
		server: server_addr.hostname,
		server_port: strToInt(server_addr.port),
		path: (server_addr.pathname !== '/') ? server_addr.pathname : null,
	}
}

function generate_outbound(node) {
	const outbound = renderOutbound(node, self_mark);
	if (outbound && node['.name'])
		outbound.tag = get_node_outbound_tag(node['.name']);
	return outbound;
}

function generate_endpoint(node) {
	const endpoint = renderEndpoint(node);
	if (endpoint && node['.name'])
		endpoint.tag = get_node_outbound_tag(node['.name']);
	return endpoint;
}

/* Config helper end */

const config = {};

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* HTTP clients */
config.http_clients = [
	{
		tag: 'direct-http',
		routing_mark: strToInt(self_mark)
	}
];

/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: true,
		server: ntp_server,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};

/* DNS start */
/* Default settings */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: self_mark ? 'direct-out' : null
		},
		{
			tag: 'system-dns',
			type: 'local',
			detour: self_mark ? 'direct-out' : null
		}
	],
	rules: [],
	reverse_mapping: true,
	strategy: dns_default_strategy,
	disable_cache: false,
	disable_expire: false
};

if (!isEmpty(main_node)) {
	/* Main DNS */
	push(config.dns.servers, {
		tag: 'main-dns',
		domain_resolver: {
			server: 'default-dns',
			strategy: (ipv6_support !== '1') ? 'ipv4_only' : null
		},
		detour: 'main-out',
		...parse_dnsserver(dns_server, 'tcp')
	});
	config.dns.final = 'main-dns';

	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns'
		});

	/* Filter out SVCB/HTTPS queries for "exquisite" Apple devices */
	if (length(proxy_domain_list))
		push(config.dns.rules, {
			rule_set: 'proxy-domain',
			query_type: [64, 65],
			action: 'reject'
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.dns.servers, {
			tag: 'china-dns',
			domain_resolver: {
				server: 'default-dns',
				strategy: 'prefer_ipv6'
			},
			detour: self_mark ? 'direct-out' : null,
			...parse_dnsserver(china_dns_server)
		});

		if (length(proxy_domain_list))
			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});

		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns'
		});
		push(config.dns.rules, {
			action: 'evaluate',
			server: 'main-dns'
		});
		push(config.dns.rules, {
			rule_set: 'geoip-cn',
			match_response: true,
			action: 'route',
			server: 'china-dns'
		});
		push(config.dns.rules, {
			match_response: true,
			action: 'respond'
		});
		push(config.dns.rules, {
			action: 'route',
			server: 'china-dns'
		});
	}
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

push(config.inbounds, {
	type: 'mixed',
	tag: 'mixed-in',
	listen: '::',
	listen_port: int(mixed_port),
	udp_timeout: strToTime(udp_timeout),
	set_system_proxy: false
});

if (tproxy_enabled)
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',

		listen: '::',
		listen_port: int(tproxy_port),
		udp_timeout: strToTime(udp_timeout)
	});
if (tun_enabled)
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',

		interface_name: tun_name,
		address: (ipv6_support === '1') ? [tun_addr4, tun_addr6] : [tun_addr4],
		mtu: strToInt(tun_mtu),
		auto_route: true,
		auto_redirect: true,
		dns_mode: 'hijack',
		route_exclude_address_set: fast_bypass_mainland ? ['geoip-cn'] : null,
		include_interface: length(listen_interfaces) ? listen_interfaces : null,
		udp_timeout: strToTime(udp_timeout),
		stack: tcpip_stack
	});
/* Inbound end */

/* Outbound start */
config.endpoints = [];

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	}
];

/* Main outbounds */
if (!isEmpty(main_node)) {
	let urltest_nodes = [];

	if (main_node === 'urltest') {
		const main_urltest_nodes = filterExistingNodes(
			uci, uciconfig, uci.get(uciconfig, ucimain, 'main_urltest_nodes')
		);
		if (!length(main_urltest_nodes))
			die('Main URLTest group has no available nodes.');
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval') || '90';
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance');
		const main_urltest_interrupt = uci.get(uciconfig, ucimain, 'main_urltest_interrupt_exist_connections') || '0';

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => get_node_outbound_tag(k)),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
			interrupt_exist_connections: strToBool(main_urltest_interrupt)
		});
		urltest_nodes = main_urltest_nodes;
	} else {
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
		if (main_node_cfg.type === 'wireguard') {
			const main_endpoint = generate_endpoint(main_node_cfg);
			if (main_endpoint) {
				main_endpoint.tag = 'main-out';
				push(config.endpoints, main_endpoint);
			}
		} else {
			const main_outbound = generate_outbound(main_node_cfg);
			if (main_outbound) {
				main_outbound.tag = 'main-out';
				push(config.outbounds, main_outbound);
			}
		}
	}

	for (let i in urltest_nodes) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = generate_endpoint(urltest_node);
			if (endpoint)
				push(config.endpoints, endpoint);
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound)
				push(config.outbounds, outbound);
		}
	}
}

if (isEmpty(config.endpoints))
	config.endpoints = null;
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [
		{
			inbound: 'dns-in',
			action: 'hijack-dns'
		}
	],
	rule_set: [],
	auto_detect_interface: isEmpty(default_interface) ? true : null,
	default_interface: default_interface,
	find_neighbor: has_mac_control() ? true : null
};
config.route.default_http_client = 'direct-http';

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

	/* Native auto_redirect pre-match: force exceptions first, then bypass. */
	if (tun_enabled) {
		add_control_pre_match_rules(config.route.rules, 'main-out');

		if (length(direct_domain_list))
			push_bypass(config.route.rules, tun_match({ rule_set: 'direct-domain' }));

		if (length(proxy_domain_list))
			push_route(config.route.rules, tun_match({ rule_set: 'proxy-domain' }), 'main-out');

		if (routing_mode === 'bypass_mainland_china' && force_proxy_rules) {
			push_bypass(config.route.rules, tun_match({ rule_set: 'geosite-cn' }));
			push_bypass(config.route.rules, tun_match({ rule_set: 'geoip-cn' }));
		}
	}

	push(config.route.rules, { action: 'sniff' });
	add_control_rules(config.route.rules, 'main-out');

	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rules, {
			rule_set: 'proxy-domain',
			action: 'route',
			outbound: 'main-out'
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.route.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			outbound: 'direct-out'
		});
		push(config.route.rules, {
			rule_set: 'geoip-cn',
			action: 'route',
			outbound: 'direct-out'
		});
	}

	config.route.final = 'main-out';

	/* Rule set */
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: render_domain_rules(direct_domain_list)
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: render_domain_rules(proxy_domain_list)
		});

	if (routing_mode === 'bypass_mainland_china') {
		add_mainland_rule_sets(config.route.rule_set);
	}

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
}
/* Routing rules end */

/* Experimental start */
const enable_clash_api = main_node === 'urltest';
const enable_cache_file = routing_mode === 'bypass_mainland_china';
if (enable_clash_api || enable_cache_file) {
	config.experimental = {
		clash_api: enable_clash_api ? {
			external_controller: `127.0.0.1:${clash_api_port}`
		} : null,
		cache_file: enable_cache_file ? {
			enabled: true,
			path: HP_DIR + '/cache/cache.db',
			store_dns: false
		} : null
	};
}
/* Experimental end */

/* Services */
if (dashboard_enabled)
	config.services = [
		{
			type: 'api',
			tag: 'api',
			listen: '::',
			listen_port: dashboard_port,
			secret: dashboard_secret,
			dashboard: {
				enabled: true,
				path: dashboard_path
			}
		}
	];

system('mkdir -p ' + RUN_DIR);
if (!writefile(RUN_DIR + '/sing-box-c.json.new', sprintf('%.J\n', removeBlankAttrs(config))))
	exit(1);
