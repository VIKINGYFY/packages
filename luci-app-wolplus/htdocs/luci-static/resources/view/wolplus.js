'use strict';
'require form';
'require rpc';
'require ui';
'require uci';
'require view';
'require tools.widgets as widgets';

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

return view.extend({
	callWake: rpc.declare({
		object: 'luci.wolplus',
		method: 'wake',
		params: [ 'iface', 'mac' ],
		expect: { '': {} }
	}),

	callHostHints: rpc.declare({
		object: 'luci-rpc',
		method: 'getHostHints',
		expect: { '': {} }
	}),

	load: function() {
		return Promise.all([
			L.resolveDefault(this.callHostHints(), {}),
			uci.load('wolplus')
		]);
	},

	render: function(data) {
		var hosts = data[0] || {};
		var m, s, o;
		var view = this;

		m = new form.Map('wolplus', _('Wake on LAN +'),
			_('Wake on LAN + is a mechanism to remotely boot computers in the local network.'));

		s = m.section(form.GridSection, 'macclient', _('Host Clients'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.actionstitle = _('Operation');

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'macaddr', _('MAC Address'));
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

		s.renderRowActions = function(section_id) {
			var wakeButton = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					return view.handleWakeup(section_id);
				})
			}, _('Awake'));

			return E('td', {
				'class': 'td cbi-section-table-cell nowrap cbi-section-actions'
			}, E('div', [
				renderDragHandle(this),
				wakeButton,
				renderEditButton(this, section_id),
				renderDeleteButton(this, section_id)
			]));
		};

		return m.render();
	},

	handleWakeup: function(section_id) {
		var name = uci.get('wolplus', section_id, 'name') || section_id;
		var mac = uci.get('wolplus', section_id, 'macaddr');
		var iface = uci.get('wolplus', section_id, 'maceth') || 'br-lan';

		if (!mac) {
			ui.addNotification(null, E('p', _('Please save the client before waking it up.')), 'error');
			return Promise.resolve();
		}

		return this.callWake(iface, mac).then(function(res) {
			var output = (res.stdout || res.stderr || '').replace(/\s+$/, '').trim();
			var message = output || _('Wake command completed with code %d.').format(res.code || 0);
			var level = (res.code == null || res.code === 0) ? 'info' : 'error';

			ui.addNotification(null, E('p', [
				_('Wake Up Host'), ': ', name, ' (', mac, ')',
				E('br'), message
			]), level);
		}).catch(function(err) {
			ui.addNotification(null, E('p', _('Wake command failed: %s').format(err.message || err)), 'error');
		});
	}
});
