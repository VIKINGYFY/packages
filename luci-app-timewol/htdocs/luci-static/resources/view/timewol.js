'use strict';
'require dom';
'require form';
'require poll';
'require rpc';
'require uci';
'require view';
'require tools.widgets as widgets';

var callHostHints = rpc.declare({
	object: 'luci-rpc',
	method: 'getHostHints',
	expect: { '': {} }
});

var callUciGet = rpc.declare({
	object: 'uci',
	method: 'get',
	params: [ 'config' ],
	expect: { values: {} }
});

function isTrue(value) {
	if (typeof(value) == 'string')
		value = value.toLowerCase();

	return value === true || value === '1' || value === 'on' || value === 'true' || value === 'yes' || value === 'enabled';
}

function getBasicEnable(config) {
	for (var sid in config)
		if (config[sid] && config[sid]['.type'] == 'basic')
			return config[sid].enable;

	return '0';
}

function renderStatus(running) {
	return E('span', {
		'style': 'font-weight:bold;font-style:italic;color:%s'.format(running ? 'green' : 'red')
	}, [ _('Timed Wake on LAN'), ': ', running ? _('Running') : _('Not running') ]);
}

function getRunningStatus() {
	return L.resolveDefault(callUciGet('timewol'), {}).then(function(config) {
		return isTrue(getBasicEnable(config));
	});
}

function updateStatus(node) {
	return getRunningStatus().then(function(running) {
		dom.content(node, renderStatus(running));
	});
}

function renderStatusSection() {
	var node = E('span', [ _('Collecting data...') ]);
	var refresh = L.bind(updateStatus, null, node);

	refresh();
	poll.add(refresh, 3);

	return E('div', { 'class': 'cbi-section' }, [
		E('p', {}, [ node ])
	]);
}

function addHostHints(option, hosts) {
	L.sortedKeys(hosts).forEach(function(mac) {
		var hint = hosts[mac].name ||
			L.toArray(hosts[mac].ipaddrs || hosts[mac].ipv4)[0] ||
			L.toArray(hosts[mac].ip6addrs || hosts[mac].ipv6)[0];

		option.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
	});

	return option;
}

function validateCronField(name, value, min, max) {
	if (value === '*')
		return true;

	if (/^[0-9]+$/.test(value)) {
		var n = +value;

		if (n >= min && n <= max)
			return true;
	}

	return _('Invalid value for %s: %s. Must be between %d and %d or "*" .').format(name, value, min, max);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callHostHints(), {}),
			uci.load('timewol')
		]);
	},

	render: function(data) {
		var hosts = data[0] || {};
		var m, s, o;

		m = new form.Map('timewol', _('Timed Wake on LAN'),
			_('Wake up your local area network devices on schedule'));

		s = m.section(form.TypedSection, 'basic');
		s.anonymous = true;
		s.render = renderStatusSection;

		s = m.section(form.TypedSection, 'basic', _('Basic Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enable', _('Enable'));
		o.rmempty = false;

		s = m.section(form.GridSection, 'macclient', _('Client Settings'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

		o = s.option(form.Value, 'macaddr', _('Client MAC'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		addHostHints(o, hosts);

		o = s.option(widgets.DeviceSelect, 'maceth', _('Network Interface'));
		o.rmempty = false;
		o.default = 'br-lan';
		o.noaliases = true;
		o.noinactive = true;

		[
			[ 'minute', _('Minute'), 0, 59, '0' ],
			[ 'hour', _('Hour'), 0, 23, '0' ],
			[ 'day', _('Day'), 1, 31, '*' ],
			[ 'month', _('Month'), 1, 12, '*' ],
			[ 'weeks', _('Week'), 0, 6, '*' ]
		].forEach(function(spec) {
			var name = spec[0];
			var title = spec[1];
			var min = spec[2];
			var max = spec[3];
			var def = spec[4];

			o = s.option(form.Value, name, title);
			o.default = def;
			o.placeholder = def;
			o.rmempty = false;
			o.validate = function(section_id, value) {
				return validateCronField(title, value, min, max);
			};
		});

		return m.render();
	}
});
