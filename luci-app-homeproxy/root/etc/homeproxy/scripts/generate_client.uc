#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { isnan } from 'math';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	hasForceProxyRules, isEmpty, parseURL, strToBool, strToInt, strToTime,
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

const ucidnssetting = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule';

const uciroutingsetting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule';

const ucinode = 'node';
const uciruleset = 'ruleset';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';

function normalize_list(value) {
	if (isEmpty(value))
		return [];
	if (type(value) === 'array')
		return value;
	return [value];
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

let main_node, default_outbound, default_outbound_dns,
    domain_strategy, dns_server, china_dns_server, dns_default_strategy,
    dns_default_server, dns_disable_cache, dns_disable_cache_expire,
    dns_client_subnet, cache_file_store_dns,
    direct_domain_list = [], proxy_domain_list = [];

if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

	dns_server = uci.get(uciconfig, ucimain, 'dns_server');
	if (isEmpty(dns_server) || dns_server === 'wan')
		dns_server = wan_dns;

	if (routing_mode === 'bypass_mainland_china') {
		china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
		if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
			china_dns_server = wan_dns;
	}
	dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

	const direct_domain_content = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
	if (direct_domain_content)
		direct_domain_list = split(direct_domain_content, /[\r\n]/);

	if (routing_mode === 'bypass_mainland_china') {
		const proxy_domain_content = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
		if (proxy_domain_content)
			proxy_domain_list = split(proxy_domain_content, /[\r\n]/);
	}

} else {
	/* DNS settings */
	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy');
	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server');
	dns_disable_cache = uci.get(uciconfig, ucidnssetting, 'disable_cache');
	dns_disable_cache_expire = uci.get(uciconfig, ucidnssetting, 'disable_cache_expire');
	dns_client_subnet = uci.get(uciconfig, ucidnssetting, 'client_subnet');
	cache_file_store_dns = uci.get(uciconfig, ucidnssetting, 'cache_file_store_dns');

	/* Routing settings */
	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
	default_outbound_dns = uci.get(uciconfig, uciroutingsetting, 'default_outbound_dns') || 'default-dns';
	domain_strategy = uci.get(uciconfig, uciroutingsetting, 'domain_strategy');
}

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'tun',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface'),
      listen_interfaces = normalize_list(uci.get(uciconfig, ucicontrol, 'listen_interfaces'));

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';
const clash_api_port = strToInt(uci.get(uciconfig, uciinfra, 'clash_api_port'));

let self_mark, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack, udp_timeout;
const tproxy_enabled = proxy_mode === 'tproxy';
const tun_enabled = proxy_mode === 'tun';

if (routing_mode === 'custom')
	udp_timeout = uci.get(uciconfig, uciroutingsetting, 'udp_timeout');
else
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
	if (routing_mode === 'custom')
		tcpip_stack = uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') || 'system';
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
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function merge_control_options(options) {
	let values = [];
	for (let option in options) {
		if (!option)
			continue;
		values = [...values, ...normalize_list(uci.get(uciconfig, ucicontrol, option))];
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
			push(ranges, item);
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

function get_control_matches() {
	const included_ports = routing_port_match();
	const mainland_mode = routing_mode === 'bypass_mainland_china';

	return {
		direct_source: source_match('lan_direct_ipv4_ips', null, 'lan_direct_mac_addrs'),
		proxy_source: mainland_mode ? source_match('lan_proxy_ipv4_ips', null, 'lan_proxy_mac_addrs') : null,
		wan_proxy: mainland_mode ? destination_match('wan_proxy_ipv4_ips', 'wan_proxy_ipv6_ips') : null,
		wan_direct: destination_match('wan_direct_ipv4_ips', 'wan_direct_ipv6_ips'),
		bypass_ports: included_ports ? { ...included_ports, invert: true } : null
	};
}

function add_control_pre_match_rules(rules, proxy_outbound) {
	const control = get_control_matches();

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
	return length(merge_control_options([
		'lan_direct_mac_addrs',
		(routing_mode === 'bypass_mainland_china') ? 'lan_proxy_mac_addrs' : null
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

function parse_dnsquery(strquery) {
	if (type(strquery) !== 'array' || isEmpty(strquery))
		return null;

	let querys = [];
	for (let i in strquery)
		isnan(int(i)) ? push(querys, i) : push(querys, int(i));

	return querys;

}

function render_dns_rule_match(cfg) {
	return {
		ip_version: strToInt(cfg.ip_version),
		query_type: parse_dnsquery(cfg.query_type),
		network: cfg.network,
		protocol: cfg.protocol,
		domain: cfg.domain,
		domain_suffix: cfg.domain_suffix,
		domain_keyword: cfg.domain_keyword,
		domain_regex: cfg.domain_regex,
		port: parse_port(cfg.port),
		port_range: cfg.port_range,
		source_ip_cidr: cfg.source_ip_cidr,
		source_ip_is_private: strToBool(cfg.source_ip_is_private),
		source_port: parse_port(cfg.source_port),
		source_port_range: cfg.source_port_range,
		process_name: cfg.process_name,
		process_path: cfg.process_path,
		process_path_regex: cfg.process_path_regex,
		user: cfg.user
	};
}

function filter_existing_nodes(nodes) {
	if (type(nodes) !== 'array' || isEmpty(nodes))
		return [];

	return filter(nodes, (k) => {
		const node = uci.get_all(uciconfig, k) || {};
		return !isEmpty(node);
	});
}

function generate_outbound(node) {
	return renderOutbound(node, self_mark);
}

function get_outbound(cfg) {
	if (isEmpty(cfg))
		return null;

	if (type(cfg) === 'array') {
		if ('any-out' in cfg)
			return 'any';

		let outbounds = [];
		for (let i in cfg)
			push(outbounds, get_outbound(i));
		return outbounds;
	} else {
		switch (cfg) {
		case 'direct-out':
			return cfg;
		default:
			const node = uci.get(uciconfig, cfg, 'node');
			if (isEmpty(node))
				die(sprintf("%s's node is missing, please check your configuration.", cfg));
			else if (node === 'urltest')
				return 'cfg-' + cfg + '-out';
			else
				return 'cfg-' + node + '-out';
		}
	}
}

function get_resolver(cfg) {
	if (isEmpty(cfg))
		return null;

	switch (cfg) {
	case 'default-dns':
	case 'system-dns':
		return cfg;
	default:
		return 'cfg-' + cfg + '-dns';
	}
}

function get_ruleset(cfg) {
	if (isEmpty(cfg))
		return null;

	let rules = [];
	for (let i in cfg)
		push(rules, isEmpty(i) ? null : 'cfg-' + i + '-rule');
	return rules;
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
	disable_cache: strToBool(dns_disable_cache),
	disable_expire: strToBool(dns_disable_cache_expire),
	client_subnet: dns_client_subnet
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
} else if (!isEmpty(default_outbound)) {
	/* DNS servers */
	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		let outbound = get_outbound(cfg.outbound);
		if (outbound === 'direct-out' && isEmpty(self_mark))
			outbound = null;

		push(config.dns.servers, {
			tag: 'cfg-' + cfg['.name'] + '-dns',
			type: cfg.type,
			server: cfg.server,
			server_port: strToInt(cfg.server_port),
			path: cfg.path,
			headers: cfg.headers,
			tls: cfg.tls_sni ? {
				enabled: true,
				server_name: cfg.tls_sni
			} : null,
			domain_resolver: (cfg.domain_resolver || cfg.domain_strategy) ? {
				server: get_resolver(cfg.domain_resolver || dns_default_server),
				strategy: cfg.domain_strategy
			} : null,
			detour: outbound
		});
	});

	/* DNS rules */
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		const action = cfg.action || 'route';
		const match_response = strToBool(cfg.match_response) ||
			!isEmpty(cfg.ip_cidr) || strToBool(cfg.ip_is_private);
		const match_fields = render_dns_rule_match(cfg);

		if (match_response)
			push(config.dns.rules, {
				...match_fields,
				action: 'evaluate',
				server: get_resolver(cfg.evaluate_server || dns_default_server)
			});

		push(config.dns.rules, {
			...match_fields,
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			match_response: match_response,
			invert: strToBool(cfg.invert),
			action: action,
			server: (action in ['route', 'evaluate']) ? get_resolver(cfg.server) : null,
			disable_cache: (action in ['route', 'evaluate', 'route-options']) ? strToBool(cfg.dns_disable_cache) : null,
			rewrite_ttl: (action in ['route', 'evaluate', 'route-options']) ? strToInt(cfg.rewrite_ttl) : null,
			client_subnet: (action in ['route', 'evaluate', 'route-options']) ? cfg.client_subnet : null,
			method: (action === 'reject') ? cfg.reject_method : null,
			no_drop: (action === 'reject') ? strToBool(cfg.reject_no_drop) : null,
			rcode: (action === 'predefined') ? cfg.predefined_rcode : null,
			answer: (action === 'predefined') ? cfg.predefined_answer : null,
			ns: (action === 'predefined') ? cfg.predefined_ns : null,
			extra: (action === 'predefined') ? cfg.predefined_extra : null
		});
	});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	config.dns.final = get_resolver(dns_default_server);
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
		const main_urltest_nodes = filter_existing_nodes(
			normalize_list(uci.get(uciconfig, ucimain, 'main_urltest_nodes'))
		);
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval');
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance');
		const main_urltest_interrupt = uci.get(uciconfig, ucimain, 'main_urltest_interrupt_exist_connections') || '1';

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => `cfg-${k}-out`),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
			interrupt_exist_connections: strToBool(main_urltest_interrupt)
		});
		urltest_nodes = main_urltest_nodes;
	} else {
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
		if (main_node_cfg.type === 'wireguard') {
			const main_endpoint = renderEndpoint(main_node_cfg);
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
			const endpoint = renderEndpoint(urltest_node);
			if (endpoint) {
				endpoint.tag = 'cfg-' + i + '-out';
				push(config.endpoints, endpoint);
			}
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound) {
				outbound.tag = 'cfg-' + i + '-out';
				push(config.outbounds, outbound);
			}
		}
	}
} else if (!isEmpty(default_outbound)) {
	let urltest_nodes = [],
	    routing_nodes = [];

	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		if (cfg.node === 'urltest') {
			const urltest_list = filter_existing_nodes(normalize_list(cfg.urltest_nodes));
			push(config.outbounds, {
				type: 'urltest',
				tag: 'cfg-' + cfg['.name'] + '-out',
				outbounds: map(urltest_list, (k) => `cfg-${k}-out`),
				url: cfg.urltest_url,
				interval: strToTime(cfg.urltest_interval),
				tolerance: strToInt(cfg.urltest_tolerance),
				idle_timeout: strToTime(cfg.urltest_idle_timeout),
				interrupt_exist_connections: strToBool(cfg.urltest_interrupt_exist_connections || '1')
			});
			urltest_nodes = [...urltest_nodes, ...filter(urltest_list, (l) => !~index(urltest_nodes, l))];
		} else {
			const outbound = uci.get_all(uciconfig, cfg.node) || {};
			if (isEmpty(outbound))
				return;

			if (outbound.type === 'wireguard') {
				const endpoint = renderEndpoint(outbound);
				if (!endpoint)
					return;

				endpoint.bind_interface = cfg.bind_interface;
				endpoint.detour = get_outbound(cfg.outbound);
				if (cfg.domain_resolver)
					endpoint.domain_resolver = {
						server: get_resolver(cfg.domain_resolver),
						strategy: cfg.domain_strategy
					};
				push(config.endpoints, endpoint);
			} else {
				const routed_outbound = generate_outbound(outbound);
				if (!routed_outbound)
					return;

				routed_outbound.bind_interface = cfg.bind_interface;
				routed_outbound.detour = get_outbound(cfg.outbound);
				if (cfg.domain_resolver)
					routed_outbound.domain_resolver = {
						server: get_resolver(cfg.domain_resolver),
						strategy: cfg.domain_strategy
					};
				push(config.outbounds, routed_outbound);
			}
			push(routing_nodes, cfg.node);
		}
	});

	for (let i in filter(urltest_nodes, (l) => !~index(routing_nodes, l))) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = renderEndpoint(urltest_node);
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
} else if (!isEmpty(default_outbound)) {
	config.route.default_domain_resolver = {
		server: get_resolver(default_outbound_dns)
	};
	if (tun_enabled)
		add_control_pre_match_rules(config.route.rules, null);
	push(config.route.rules, { action: 'sniff' });
	add_control_rules(config.route.rules, null);

	const bypass_cn_traffic = uci.get(uciconfig, uciroutingsetting, 'bypass_cn_traffic') === '1';
	if (bypass_cn_traffic) {
		push(config.route.rules, {
			rule_set: ['geosite-cn', 'geoip-cn'],
			action: 'route',
			outbound: 'direct-out'
		});
		add_mainland_rule_sets(config.route.rule_set);
	}

	if (domain_strategy)
		push(config.route.rules, {
			action: 'resolve',
			strategy: domain_strategy
		});

	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		const action = cfg.action || 'route';
		const is_route_action = action in ['route', 'route-options'];
		const rule = {
			ip_version: strToInt(cfg.ip_version),
			protocol: cfg.protocol,
			client: cfg.client,
			network: cfg.network,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			source_ip_cidr: cfg.source_ip_cidr,
			source_ip_is_private: strToBool(cfg.source_ip_is_private),
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			process_path_regex: cfg.process_path_regex,
			user: cfg.user,
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			invert: strToBool(cfg.invert),
			action: action,
			outbound: (action === 'route') ? get_outbound(cfg.outbound) : null,
			override_address: is_route_action ? cfg.override_address : null,
			override_port: is_route_action ? strToInt(cfg.override_port) : null,
			udp_disable_domain_unmapping: is_route_action ? strToBool(cfg.udp_disable_domain_unmapping) : null,
			udp_connect: is_route_action ? strToBool(cfg.udp_connect) : null,
			udp_timeout: is_route_action ? strToTime(cfg.udp_timeout) : null,
			tls_fragment: is_route_action ? strToBool(cfg.tls_fragment) : null,
			tls_fragment_fallback_delay: is_route_action ? strToTime(cfg.tls_fragment_fallback_delay) : null,
			tls_record_fragment: is_route_action ? strToBool(cfg.tls_record_fragment) : null,
			server: (action === 'resolve') ? get_resolver(cfg.resolve_server) : null,
			strategy: (action === 'resolve') ? cfg.resolve_strategy : null,
			disable_cache: (action === 'resolve') ? strToBool(cfg.resolve_disable_cache) : null,
			rewrite_ttl: (action === 'resolve') ? strToInt(cfg.resolve_rewrite_ttl) : null,
			client_subnet: (action === 'resolve') ? cfg.resolve_client_subnet : null,
			method: (action === 'reject') ? cfg.reject_method : null,
			no_drop: (action === 'reject' && cfg.reject_method !== 'drop') ? strToBool(cfg.reject_no_drop) : null
		};

		if (action === 'route-options' && isEmpty(removeBlankAttrs({
			override_address: rule.override_address,
			override_port: rule.override_port,
			udp_disable_domain_unmapping: rule.udp_disable_domain_unmapping,
			udp_connect: rule.udp_connect,
			udp_timeout: rule.udp_timeout,
			tls_fragment: rule.tls_fragment,
			tls_fragment_fallback_delay: rule.tls_fragment_fallback_delay,
			tls_record_fragment: rule.tls_record_fragment
		})))
			return null;

		push(config.route.rules, rule);
	});

	if (default_outbound === 'reject')
		push(config.route.rules, { action: 'reject' });
	else
		config.route.final = get_outbound(default_outbound);

	/* Rule set */
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		const ruleset_outbound = (cfg.type === 'remote') ? (get_outbound(cfg.outbound) || 'direct-out') : null;
		push(config.route.rule_set, {
			type: cfg.type,
			tag: 'cfg-' + cfg['.name'] + '-rule',
			format: cfg.format,
			path: cfg.path,
			url: cfg.url,
			http_client: (ruleset_outbound === 'direct-out') ? 'direct-http' :
				(ruleset_outbound ? { detour: ruleset_outbound } : null),
			update_interval: cfg.update_interval
		});
	});
}
/* Routing rules end */

/* Experimental start */
const enable_clash_api = main_node === 'urltest';
const enable_cache_file = routing_mode in ['bypass_mainland_china', 'custom'];
if (enable_clash_api || enable_cache_file) {
	config.experimental = {
		clash_api: enable_clash_api ? {
			external_controller: `127.0.0.1:${clash_api_port}`
		} : null,
		cache_file: enable_cache_file ? {
			enabled: true,
			path: HP_DIR + '/cache/cache.db',
			store_dns: strToBool(cache_file_store_dns)
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
