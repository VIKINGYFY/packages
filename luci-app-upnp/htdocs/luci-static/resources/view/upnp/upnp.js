'use strict';
'require view';
'require poll';
'require rpc';
'require uci';
'require form';
'require upnp';

const callInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { interface: [] }
});

function parseValidatedSection() {
	const sid = this.section;
	// LuCI parses fields independently. Validate the section before any field
	// can leave a cached UCI change behind when another field fails validation.
	const invalid = this.children.find(option => {
		if (!option.isActive(sid))
			return false;
		if (!option.isValid(sid))
			return true;
		const value = option.formvalue(sid);
		return !option.optional && !option.rmempty && (value == null || value == '');
	});
	return invalid ? invalid.parse(sid) : form.NamedSection.prototype.parse.call(this);
}

function upnpOption(section, tab, type, name, title, description) {
	const option = section.taboption(tab, type, name, title, description);
	option.depends('enable_upnp', '1');
	option.retain = true;
	return option;
}

function addServiceOptions(section, enabled, interfaces) {
	const upnpEnabled = section.taboption('setup', form.Flag, 'enable_upnp', _('Enable UPnP IGD protocol'));
	upnpEnabled.default = '1';

	const pcpEnabled = section.taboption('setup', form.Flag, 'enable_natpmp', _('Enable PCP/NAT-PMP protocols'));
	pcpEnabled.default = '1';

	enabled.validate = sid => enabled.formvalue(sid) !== '1' || upnpEnabled.formvalue(sid) === '1' ||
		pcpEnabled.formvalue(sid) === '1' || _('Enable at least one port mapping protocol.');

	let o = section.taboption('setup', form.Flag, 'ext_allow_private_ipv4', _('Allow mappings on a private WAN IPv4 address'),
		_('Allows local port mappings when the WAN address is private or reserved. Internet reachability depends on the upstream router and firewall.'));
	o.default = '1';
	o.rmempty = false;

	o = upnpOption(section, 'setup', form.Flag, 'igdv1', _('UPnP IGDv1 compatibility mode'),
		_('Advertise an IGDv1 description for older UPnP clients.'));
	o.default = '1';
	o.rmempty = false;

	const bitrateDescription = _('Reported to UPnP clients in KiB/s. Leave empty or enter 0 to use the detected WAN link speed.');
	o = upnpOption(section, 'setup', form.Value, 'download', _('Reported download speed'), bitrateDescription);
	o.datatype = 'and(uinteger,range(0,524287))';

	o = upnpOption(section, 'setup', form.Value, 'upload', _('Reported upload speed'), bitrateDescription);
	o.datatype = 'and(uinteger,range(0,524287))';

	// Keep existing network names selectable even when their interfaces are down.
	const internal = uci.get('upnpd', 'config', 'internal_iface');
	const external = uci.get('upnpd', 'config', 'external_iface');
	const names = Array.from(new Set([
		'lan', ...interfaces.map(iface => iface.interface).filter(name => name && name !== 'loopback'),
		...L.toArray(internal), ...L.toArray(external)
	])).sort(L.naturalCompare);

	const lan = section.taboption('advanced', form.MultiValue, 'internal_iface', _('Listening networks'),
		_('Choose the internal networks allowed to request port mappings. The default network is lan.'));
	lan.default = 'lan';
	lan.rmempty = false;
	lan.validate = (sid, value) => L.toArray(value).length > 0 || _('Select at least one listening network.');
	lan.write = function(sid, value) {
		const current = this.cfgvalue(sid);
		const selected = L.toArray(value);
		if (selected.join(' ') !== L.toArray(current ?? this.default).join(' '))
			return form.Value.prototype.write.call(this, sid, Array.isArray(current) ? selected : selected.join(' '));
	};

	const wan = section.taboption('advanced', form.ListValue, 'external_iface', _('External IPv4 network'),
		_('Choose the WAN network used for IPv4 port mappings. Automatic selection follows the IPv4 default route or configured external firewall zone.'));
	wan.value('', _('Automatic'));
	wan.validate = (sid, value) => !value || !L.toArray(lan.formvalue(sid)).includes(value) ||
		_('The external network must differ from the listening networks.');
	for (const name of names) {
		lan.value(name);
		wan.value(name);
	}

	const useStun = section.taboption('advanced', form.Flag, 'use_stun', _('Use STUN'),
		_('Detect the public IPv4 address and check whether the upstream NAT permits incoming traffic. A failed STUN request prevents the service from starting.'));

	const externalIP = section.taboption('advanced', form.Value, 'external_ip', _('Advertised external IPv4 address'),
		_('Override the IPv4 address reported to clients. Leave empty to use the detected address.'));
	externalIP.datatype = 'ip4addr(1)';
	useStun.validate = sid => useStun.formvalue(sid) !== '1' || !externalIP.formvalue(sid) ||
		_('STUN and a manually configured external IPv4 address are mutually exclusive.');

	o = section.taboption('advanced', form.Value, 'stun_host', _('STUN host'));
	o.depends('use_stun', '1');
	o.datatype = 'host(1)';
	o.rmempty = false;
	o.retain = true;

	o = section.taboption('advanced', form.Value, 'stun_port', _('STUN port'));
	o.depends('use_stun', '1');
	o.datatype = 'port';
	o.placeholder = '3478';
	o.retain = true;

	o = upnpOption(section, 'advanced', form.Flag, 'secure_mode', _('Enable secure mode'),
		_('Allow UPnP clients to add or delete IPv4 mappings for their own address only.'));
	o.default = '1';

	o = upnpOption(section, 'advanced', form.Value, 'notify_interval', _('Notify interval'),
		_('SSDP announcement interval in seconds. Announcements advertise a lifetime of twice this value.'));
	o.datatype = 'and(uinteger,range(1,1073741823))';
	o.placeholder = '900';

	o = upnpOption(section, 'advanced', form.Value, 'port', _('SOAP/HTTP port'),
		_('The default is 5000. Enter 0 to select a port automatically.'));
	o.datatype = 'port';
	o.placeholder = '5000';

	o = upnpOption(section, 'advanced', form.Value, 'presentation_url', _('Presentation URL'),
		_('Report custom router web interface (presentation) URL'));
	o.placeholder = 'http://192.168.1.1/';

	upnpOption(section, 'advanced', form.Value, 'uuid', _('Device UUID'));
	upnpOption(section, 'advanced', form.Value, 'model_number', _('Announced model number'));
	upnpOption(section, 'advanced', form.Value, 'serial_number', _('Announced serial number'));

	o = upnpOption(section, 'advanced', form.Flag, 'system_uptime', _('Report system instead of service uptime'));
	o.default = '1';

	o = section.taboption('advanced', form.Value, 'upnp_lease_file', _('IPv4 lease file'),
		_('Stores IPv4 mapping descriptions and expiry times and is used when deleting mappings. Leave empty to use the default path.'));
	o.placeholder = '/var/run/miniupnpd.leases';
}

function addAcl(map) {
	const section = map.section(form.GridSection, 'perm_rule', _('IPv4 Access Control List'),
		_('Applies to IPv4 mappings for all enabled protocols. The first matching rule wins. Unmatched requests are allowed unless a final deny rule covers them.'));
	section.sortable = true;
	section.anonymous = true;
	section.addremove = true;
	section.addModalOptions = modal => { modal.parse = parseValidatedSection; };

	section.option(form.Value, 'comment', _('Comment'));

	let o = section.option(form.Value, 'int_addr', _('Client Address'));
	o.datatype = 'ip4addr';
	o.placeholder = '0.0.0.0/0';
	o.rmempty = false;

	o = section.option(form.Value, 'int_ports', _('Client Port'));
	o.datatype = 'portrange';
	o.placeholder = '0-65535';
	o.rmempty = false;

	o = section.option(form.Value, 'ext_ports', _('External Port'));
	o.datatype = 'portrange';
	o.placeholder = '0-65535';
	o.rmempty = false;

	o = section.option(form.ListValue, 'action', _('Action'));
	o.value('allow', _('Allow'));
	o.value('deny', _('Deny'));
	o.default = 'deny';
	o.rmempty = false;
}

return view.extend({
	load: function() {
		return Promise.all([
			upnp.getStatus(),
			uci.load('upnpd'),
			L.resolveDefault(callInterfaces(), [])
		]);
	},

	render: function(data) {

		let m, s;

		var protocols = '%s & %s/%s'.format(
			'<a href="https://en.wikipedia.org/wiki/Internet_Gateway_Device_Protocol" target="_blank" rel="noreferrer"><abbr title="UPnP Internet Gateway Device (Control Protocol)">UPnP IGD</abbr></a>',
			'<a href="https://en.wikipedia.org/wiki/Port_Control_Protocol" target="_blank" rel="noreferrer"><abbr title="Port Control Protocol">PCP</abbr></a>',
			'<a href="https://en.wikipedia.org/wiki/NAT_Port_Mapping_Protocol" target="_blank" rel="noreferrer"><abbr title="NAT Port Mapping Protocol">NAT-PMP</abbr></a>');
		m = new form.Map('upnpd', [_('UPnP IGD & PCP/NAT-PMP Service')],
			_('The %s protocols allow clients on the local network to configure port maps/forwards on the router autonomously.',
				'The %s (%s = UPnP IGD & PCP/NAT-PMP) protocols allow clients on the local network to configure port maps/forwards on the router autonomously.')
				.format(protocols)
		);

		s = m.section(form.GridSection, '_active_rules');

		s.render = function() {
			return E('div', { 'class': 'cbi-section cbi-tblsection' }, [
				E('h3', _('Active IPv4 Port Mappings')), upnp.renderTable(data[0])
			]);
		};

		const customConfig = uci.get('upnpd', 'config', 'config_file');
		s = m.section(form.NamedSection, 'config', 'upnpd', _('Service Settings'), customConfig ?
			_('A custom MiniUPnPd configuration file is active. This page can set the service and logging switches.') : '');
		s.addremove = false;
		s.parse = parseValidatedSection;
		s.tab('setup', _('Service Setup'));
		s.tab('advanced', _('Advanced Settings'));

		const enabled = s.taboption('setup', form.Flag, 'enabled', _('Start service'),
			_('Start autonomous port mapping service'));
		enabled.rmempty = false;

		if (!customConfig)
			addServiceOptions(s, enabled, data[2]);

		s.taboption('advanced', form.Flag, 'log_output', _('Enable additional logging'),
			_('Puts extra debugging information into the system log'));

		if (!customConfig)
			addAcl(m);

		return m.render().then(L.bind(function(m, nodes) {
			poll.add(L.bind(function() {
				const table = nodes.querySelector('.upnp-status-table');
				return upnp.getStatus().then(rules => upnp.updateTable(table, rules));
			}, this), 5);
			return nodes;
		}, this, m));
	}
});
