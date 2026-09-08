/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require homeproxy as hp';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

const callReadDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

function normalizeDomainList(value) {
	value = (value || '').trim().replace(/\r\n?/g, '\n');
	return value ? value + '\n' : '';
}

function writeDomainList(type, checksumOption, value) {
	const content = normalizeDomainList(value);

	return callWriteDomainList(type, content).then((result) => {
		if (!result.result)
			throw new Error(_('Failed to save domain list.'));
		uci.set('homeproxy', 'control', checksumOption, hp.calcStringMD5(content));
		return result;
	});
}

const callCurrentNode = rpc.declare({
	object: 'luci.homeproxy',
	method: 'current_node_get',
	expect: { '': {} }
});

function renderStatus(isRunning, version, currentNode) {
	let spanTemp = '<em><span style="color:%s"><strong>%s (sing-box v%s) %s</strong></span></em>';
	let renderHTML;
	let statusColor = isRunning ? 'green' : 'red';
	let nodeColor = '#1e90ff';
	if (isRunning)
		renderHTML = spanTemp.format(statusColor, _('HomeProxy'), version, _('RUNNING'));
	else
		renderHTML = spanTemp.format(statusColor, _('HomeProxy'), version, _('NOT RUNNING'));

	if (currentNode)
		renderHTML += '<div><em><span style="color:%s"><strong>%s</strong></span></em></div>'.format(nodeColor, '%h'.format(currentNode));

	return renderHTML;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

return view.extend({
	load() {
		return Promise.all([
			uci.load('homeproxy'),
			hp.getBuiltinFeatures(),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		let features = data[1],
		    hosts = data[2]?.hosts;

		/* Cache all configured proxy nodes, they will be called multiple times */
		let proxy_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = res.address || '',
			    nodeport = res.port || '',
			    endpoint = nodeaddr && nodeport ? ((stubValidator.apply('ip6addr', nodeaddr) ?
				String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport) : res['.name'];

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || endpoint);
		});

		m = new form.Map('homeproxy', _('HomeProxy'),
			_('The modern ImmortalWrt proxy platform for ARM64/AMD64. — AI Edition'));

		s = m.section(form.TypedSection);
		s.render = function () {
			poll.add(function () {
				return Promise.all([
					L.resolveDefault(hp.getServiceStatus('sing-box-c'), false),
					L.resolveDefault(callCurrentNode(), null)
				]).then((res) => {
					let isRunning = res[0],
					    current = res[1],
					    current_label = null;

					if (current?.mode === 'urltest') {
						let active = current.active || {};
						let nodeName = (active?.id && active.id !== 'urltest') ? (proxy_nodes[active.id] || active.label || active.id) : _('Invalid node');

						current_label = _('URLTest: %s').format(nodeName);
					}
					let view = document.getElementById('service_status');
					view.innerHTML = renderStatus(isRunning, features.version, current_label);
				});
			});

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');

		s.tab('routing', _('Routing Settings'));
		s.tab('dashboard', _('Dashboard'));

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'));
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', hp.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
		o.depends({ routing_mode: 'global', main_node: 'urltest' });
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '90';
		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
		o.depends({ routing_mode: 'global', main_node: 'urltest' });
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
		o.depends({ routing_mode: 'global', main_node: 'urltest' });
		o.retain = true;

		o = s.taboption('routing', form.Flag, 'main_urltest_interrupt_exist_connections', _('Interrupt existing connections'),
			_('Interrupt existing connections when the selected outbound has changed.'));
		o.default = o.disabled;
		o.rmempty = false;
		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
		o.depends({ routing_mode: 'global', main_node: 'urltest' });
		o.retain = true;

		o = s.taboption('routing', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://dns.cloudflare.com/dns-query', _('Cloudflare Public DNS (DoH)'));
		o.value('https://dns.google/dns-query', _('Google Public DNS (DoH)'));
		o.value('https://dns.quad9.net/dns-query', _('Quad9 Public DNS (DoH)'));
		o.value('https://dns.adguard-dns.com/dns-query', _('AdGuard Public DNS (DoH)'));
		o.value('https://dns.sb/dns-query', _('DNS.SB Public DNS (DoH)'));
		o.value('https://dns.opendns.com/dns-query', _('Cisco Public DNS (DoH)'));
		o.default = 'https://dns.quad9.net/dns-query';
		o.rmempty = false;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://doh-pure.onedns.net/dns-query', _('ThreatBook Public DNS (DoH)'));
		o.value('https://doh.pub/dns-query', _('Tencent Public DNS (DoH)'));
		o.value('https://dns.alidns.com/dns-query', _('AliDNS Public DNS (DoH)'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.default = 'https://dns.alidns.com/dns-query';
		o.rmempty = false;
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'proxy_mode', _('Proxy mode'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		o.value('tun', _('TUN TCP/UDP'));
		o.value('tproxy', _('TProxy TCP/UDP'));
		o.default = 'tun';
		o.description = _('TUN uses sing-box automatic routing and redirect on Linux; TProxy uses native TCP/UDP transparent proxying.');
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack.'));
		if (features.with_gvisor) {
			o.value('mixed', 'Mixed');
			o.value('gvisor', 'gVisor');
		}
		o.value('system', 'System');
		o.default = 'mixed';
		o.depends({ routing_mode: 'bypass_mainland_china', proxy_mode: 'tun' });
		o.depends({ routing_mode: 'global', proxy_mode: 'tun' });
		o.rmempty = false;
		o.retain = true;
		o.onchange = function(ev, section_id, value) {
			let desc = ev.target.nextElementSibling;
			if (value === 'mixed')
				desc.innerHTML = _('Mixed <code>System</code> TCP stack and <code>gVisor</code> UDP stack.')
			else if (value === 'gvisor')
				desc.innerHTML = _('Based on Google/gVisor.');
			else if (value === 'system')
				desc.innerHTML = _('Less compatibility and sometimes better performance.');
		}

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = o.enabled;
		o.rmempty = false;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');

		o = s.taboption('dashboard', form.Flag, 'dashboard_enabled', _('Enable dashboard'));
		o.default = '0';
		o.rmempty = false;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');

		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'),
			_('A random available port is assigned on first installation.'));
		o.default = '9095';
		o.datatype = 'port';
		o.rmempty = false;
		o.retain = true;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');

		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
		o.password = true;
		o.rmempty = true;
		o.retain = true;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');

		o = s.taboption('dashboard', form.Button, '_open_dashboard', _('sing-box dashboard'));
		o.inputtitle = _('Open dashboard');
		o.inputstyle = 'apply';
		o.depends({ routing_mode: 'bypass_mainland_china', dashboard_enabled: '1' });
		o.depends({ routing_mode: 'global', dashboard_enabled: '1' });
		o.onclick = function() {
			let host = window.location.hostname,
			    port = uci.get('homeproxy', 'config', 'dashboard_port') || '9095';
			if (host.includes(':') && !host.startsWith('['))
				host = '[' + host + ']';
			window.open('http://' + host + ':' + port + '/dashboard/', '_blank', 'noopener,noreferrer');
		};

		/* ACL settings start */
		s.tab('control', _('Access Control'));

		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'global');
		ss = o.subsection;

		/* Interface control start */
		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;
		/* Interface control end */

		/* LAN IP policy start */
		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = ss.taboption('lan_ip_policy', form.Flag, 'lan_whitelist_mode', _('List mode'),
			_('Only devices in the lists below are processed. All other devices use direct routing.'));
		so.default = '0';
		so.rmempty = false;
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Global Direct IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global direct routing.'), 'ipv4', hosts, true);
		so.depends({
			'lan_whitelist_mode': '0',
			'homeproxy.config.routing_mode': 'bypass_mainland_china'
		});
		so.depends('homeproxy.config.routing_mode', 'global');
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Global Direct MAC addresses'),
			_('MAC addresses in this option are forced to use global direct routing.'), hosts);
		so.depends({
			'lan_whitelist_mode': '0',
			'homeproxy.config.routing_mode': 'bypass_mainland_china'
		});
		so.depends('homeproxy.config.routing_mode', 'global');
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_auto_proxy_ipv4_ips', _('Rule Proxy IPv4 addresses'),
			_('IPv4 addresses in this option automatically use rule-based proxy routing.'), 'ipv4', hosts, true);
		so.depends({
			'lan_whitelist_mode': '1',
			'homeproxy.config.routing_mode': 'bypass_mainland_china'
		});
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_auto_proxy_mac_addrs', _('Rule Proxy MAC addresses'),
			_('MAC addresses in this option automatically use rule-based proxy routing.'), hosts);
		so.depends({
			'lan_whitelist_mode': '1',
			'homeproxy.config.routing_mode': 'bypass_mainland_china'
		});
		so.retain = true;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Global Proxy IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global proxy routing.'), 'ipv4', hosts, true);
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Global Proxy MAC addresses'),
			_('MAC addresses in this option are forced to use global proxy routing.'), hosts);
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;
		/* LAN IP policy end */

		/* WAN IP policy start */
		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Global Proxy IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global proxy routing.'));
		so.datatype = 'or(ip4addr, cidr4)';
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Global Proxy IPv6 addresses'),
			_('IPv6 addresses in this option are forced to use global proxy routing.'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends({
			'homeproxy.config.routing_mode': 'bypass_mainland_china',
			'homeproxy.config.ipv6_support': '1'
		});
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Global Direct IPv4 addresses'),
			_('IPv4 addresses in this option are forced to use global direct routing.'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Global Direct IPv6 addresses'),
			_('IPv6 addresses in this option are forced to use global direct routing.'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');
		so.retain = true;
		/* WAN IP policy end */

		/* Proxy domain list start */
		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.retain = true;
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return writeDomainList('proxy_list', 'proxy_domain_list_checksum', value);
		}
		so.remove = function(/* ... */) {
			return writeDomainList('proxy_list', 'proxy_domain_list_checksum', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Proxy domain list end */

		/* Direct domain list start */
		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends('homeproxy.config.routing_mode', 'bypass_mainland_china');
		so.depends('homeproxy.config.routing_mode', 'global');
		so.retain = true;
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return writeDomainList('direct_list', 'direct_domain_list_checksum', value);
		}
		so.remove = function(/* ... */) {
			return writeDomainList('direct_list', 'direct_domain_list_checksum', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Direct domain list end */
		/* ACL settings end */

		return m.render();
	}
});
