'use strict';
'require form';
'require rpc';
'require ui';
'require uci';
'require view';
'require tools.widgets as widgets';

var callWake = rpc.declare({
	object: 'luci.wolplus',
	method: 'wake',
	params: [ 'iface', 'mac' ],
	expect: { '': {} }
});

var callHostHints = rpc.declare({
	object: 'luci-rpc',
	method: 'getHostHints',
	expect: { '': {} }
});

function addHostHints(option, hosts) {
	L.sortedKeys(hosts).forEach(function(mac) {
		var hint = hosts[mac].name ||
			L.toArray(hosts[mac].ipaddrs || hosts[mac].ipv4)[0] ||
			L.toArray(hosts[mac].ip6addrs || hosts[mac].ipv6)[0];

		option.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
	});

	return option;
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callHostHints(), {}),
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

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'macaddr', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		addHostHints(o, hosts);

		o = s.option(widgets.DeviceSelect, 'maceth', _('Network Interface'));
		o.rmempty = false;
		o.default = 'br-lan';
		o.noaliases = true;
		o.noinactive = true;

		s.renderRowActions = function(section_id) {
			var defaultButtons = form.GridSection.prototype.renderRowActions.call(this, section_id);
			var buttonContainer = defaultButtons.querySelector('div');
			var wakeButton = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					return view.handleWakeup(section_id);
				})
			}, _('Awake'));

			if (buttonContainer) {
				var editButton = buttonContainer.querySelector('.cbi-button-edit');
				buttonContainer.insertBefore(wakeButton, editButton || buttonContainer.firstChild);
			}

			return defaultButtons;
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

		return callWake(iface, mac).then(function(res) {
			res = res || {};

			var output = (res.stdout || res.stderr || '').trim();
			var code = res.code;
			var message = output || _('Wake command completed with code %d.').format(code || 0);
			var level = (code == null || code === 0) ? 'info' : 'error';

			ui.addNotification(null, E('p', [
				_('Wake Up Host'), ': ', name, ' (', mac, ')',
				E('br'), message
			]), level);
		}).catch(function(err) {
			ui.addNotification(null, E('p', _('Wake command failed: %s').format(err.message || err)), 'error');
		});
	}
});
