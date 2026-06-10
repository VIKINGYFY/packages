'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';
'require tools.widgets as widgets';

var crontabFile = '/etc/crontabs/root';

function renderDragHandle(section) {
	var touchSort = ('ontouchstart' in window);

	return E('button', {
		'type': 'button',
		'title': _('Drag to reorder'),
		'class': 'cbi-button drag-handle center',
		'style': 'cursor:move; user-select:none; -webkit-user-select:none; display:inline-block;',
		'draggable': !touchSort,
		'dragstart': !touchSort ? L.bind(function(ev) {
			this.handleDragStart(ev, ev.currentTarget.closest('.tr'));
		}, section) : null,
		'dragend': !touchSort ? L.bind(function(ev) {
			this.handleDragEnd(ev, ev.currentTarget.closest('.tr'));
		}, section) : null,
		'touchmove': touchSort ? L.bind(function(ev) {
			this.handleTouchMove(ev);
		}, section) : null,
		'touchend': touchSort ? L.bind(function(ev) {
			this.handleTouchEnd(ev);
		}, section) : null
	}, '☰');
}

function renderEditButton(section, section_id) {
	return E('button', {
		'type': 'button',
		'title': _('Edit'),
		'class': 'btn cbi-button cbi-button-edit',
		'click': ui.createHandlerFn(section, 'renderMoreOptionsModal', section_id)
	}, [ _('Edit') ]);
}

function renderDeleteButton(section, section_id) {
	var title = section.titleFn('delbtntitle', section_id) || _('Delete');

	return E('button', {
		'type': 'button',
		'title': title,
		'class': 'btn cbi-button cbi-button-remove',
		'click': ui.createHandlerFn(section, 'handleRemove', section_id),
		'disabled': section.map.readonly || null
	}, [ title ]);
}

function renderStatus(running) {
	return E('span', {
		'style': 'font-weight:bold;color:%s'.format(running ? 'green' : 'red')
	}, [ running ? _('RUNNING') : _('NOT RUNNING') ]);
}

function updateStatus(node) {
	return L.resolveDefault(fs.read(crontabFile), '').then(function(content) {
		dom.content(node, renderStatus(/\betherwake\b/.test(content || '')));
	});
}

function validateCronField(name, value, min, max) {
	if (value === '*')
		return true;

	if (/^[0-9]+$/.test(value)) {
		var n = +value;

		if (n >= min && n <= max)
			return true;
	}

	return _('Invalid value for %s: %s. Must be between %d and %d or "*".').format(name, value, min, max);
}

return view.extend({
	callHostHints: rpc.declare({
		object: 'luci-rpc',
		method: 'getHostHints',
		expect: { '': {} }
	}),

	load: function() {
		return Promise.all([
			L.resolveDefault(this.callHostHints(), {}),
			uci.load('timewol')
		]);
	},

	render: function(data) {
		var hosts = data[0] || {};
		var m, s, o;

		m = new form.Map('timewol', _('Timed Wake on LAN'),
			_('Wake up your local area network devices on schedule'));

		s = m.section(form.TypedSection, 'basic', _('Running Status'));
		s.anonymous = true;
		s.render = function() {
			var node = E('span', [ _('Collecting data...') ]);
			var refresh = L.bind(updateStatus, null, node);

			refresh();
			poll.add(refresh, 2);

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Running Status')),
				E('p', {}, [ _('Current Status'), ': ', node ])
			]);
		};

		s = m.section(form.TypedSection, 'basic', _('Basic Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enable', _('Enable'));
		o.rmempty = false;

		s = m.section(form.GridSection, 'macclient', _('Client Settings'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.actionstitle = _('Operation');
		s.renderRowActions = function(section_id) {
			return E('td', {
				'class': 'td cbi-section-table-cell nowrap cbi-section-actions'
			}, E('div', [
				renderDragHandle(this),
				renderEditButton(this, section_id),
				renderDeleteButton(this, section_id)
			]));
		};

		o = s.option(form.Value, 'macaddr', _('Client MAC'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		L.sortedKeys(hosts).forEach(function(mac) {
			var hint = hosts[mac].name ||
				L.toArray(hosts[mac].ipaddrs || hosts[mac].ipv4)[0] ||
				L.toArray(hosts[mac].ip6addrs || hosts[mac].ipv6)[0];

			o.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
		});

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
	},

	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', [ ev, mode ]).then(function() {
			return fs.exec('/etc/init.d/timewol', [ 'restart' ]);
		});
	}
});
