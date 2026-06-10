'use strict';
'require form';
'require rpc';
'require ui';
'require uci';
'require view';
'require tools.widgets as widgets';

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

		m = new form.Map('wolplus', _('Wake on LAN +'),
			_('Wake on LAN + is a mechanism to remotely boot computers in the local network.'));

		s = m.section(form.GridSection, 'macclient', _('Host Clients'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

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

		var gridSection = s;
		s.renderRowActions = L.bind(function(section_id) {
			var defaultButtons = form.GridSection.prototype.renderRowActions.call(gridSection, section_id, _('Edit'));
			var wakeButton = E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					return this.handleWakeup(section_id);
				})
			}, _('Awake'));
			var container = defaultButtons.querySelector('div');

			if (container)
				container.insertBefore(wakeButton, container.firstChild);

			return defaultButtons;
		}, this);

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
