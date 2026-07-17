'use strict';
'require form';
'require rpc';
'require ui';
'require uci';
'require view';
'require tools.widgets as widgets';

var callHostHints = rpc.declare({
	object: 'luci-rpc',
	method: 'getHostHints',
	expect: { '': {} }
});

var callSync = rpc.declare({
	object: 'luci.wolultra',
	method: 'sync',
	expect: { '': {} }
});

var callWake = rpc.declare({
	object: 'luci.wolultra',
	method: 'wake',
	params: [ 'iface', 'mac' ],
	expect: { '': {} }
});

function addHostHints(option, hosts) {
	L.sortedKeys(hosts).forEach(function(mac) {
		var hint = hosts[mac].name ||
			L.toArray(hosts[mac].ipaddrs || hosts[mac].ipv4)[0] ||
			L.toArray(hosts[mac].ip6addrs || hosts[mac].ipv6)[0];

		option.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
	});

}

function normalizeCronExpression(value) {
	return String(value || '').trim().replace(/\s+/g, ' ');
}

function cronExpression(section_id) {
	var expression = uci.get('wolultra', section_id, 'cron');

	if (expression)
		return normalizeCronExpression(expression);

	return '%s %s %s %s %s'.format(
		uci.get('wolultra', section_id, 'minute') || '0',
		uci.get('wolultra', section_id, 'hour') || '0',
		uci.get('wolultra', section_id, 'day') || '*',
		uci.get('wolultra', section_id, 'month') || '*',
		uci.get('wolultra', section_id, 'weeks') || '*');
}

function validateCronExpression(section_id, value) {
	var expression = normalizeCronExpression(value);

	if (/^[0-9*\/?, -]+$/.test(expression) && expression.split(' ').length === 5)
		return true;

	return _('Expecting: %s').format(_('valid cron expression'));
}

function cronDescription() {
	return _('Minutes (0-59), hours (0-23), days (1-31), months (1-12), weekdays (0-6).') +
		'<br/>' +
		'<a target="_blank" rel="noreferrer noopener" href="https://cron.ciding.cc/">https://cron.ciding.cc/</a>';
}

function scheduleText(section_id) {
	if (uci.get('wolultra', section_id, 'scheduled') !== '1')
		return _('Disabled');

	return cronExpression(section_id);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callHostHints(), {}),
			uci.load('wolultra')
		]);
	},

	render: function(data) {
		var hosts = data[0] || {};
		var m, s, o;
		var view = this;

		m = new form.Map('wolultra', _('WOL Ultra'),
			_('Wake local network devices immediately or on an individual schedule. — AI Edition'));

		s = m.section(form.GridSection, 'macclient', _('Client Settings'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.tab('general', _('General Settings'));
		s.tab('schedule', _('Scheduled Wake'));

		o = s.taboption('general', form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'macaddr', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		addHostHints(o, hosts);

		o = s.taboption('general', widgets.DeviceSelect, 'maceth', _('Network Interface'));
		o.rmempty = false;
		o.default = 'br-lan';
		o.noaliases = true;
		o.noinactive = true;

		o = s.taboption('schedule', form.Flag, 'scheduled', _('Scheduled Wake'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;

		o = s.taboption('schedule', form.DummyValue, '_schedule', _('Scheduled Wake'));
		o.modalonly = false;
		o.textvalue = scheduleText;

		o = s.taboption('schedule', form.Value, 'cron', _('Cron expression'), cronDescription());
		o.default = '0 0 * * *';
		o.placeholder = '0 0 * * *';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('scheduled', '1');
		o.cfgvalue = function(section_id) {
			return cronExpression(section_id);
		};
		o.validate = validateCronExpression;
		o.write = function(section_id, value) {
			uci.set('wolultra', section_id, 'cron', normalizeCronExpression(value));
			[ 'minute', 'hour', 'day', 'month', 'weeks' ].forEach(function(name) {
				uci.unset('wolultra', section_id, name);
			});
		};

		s.renderRowActions = function(section_id) {
			var defaultButtons = form.GridSection.prototype.renderRowActions.call(this, section_id);
			var buttonContainer = defaultButtons.querySelector('div');
			var wakeButton = E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					return view.handleWakeup(section_id);
				})
			}, _('Wake'));

			if (buttonContainer) {
				var editButton = buttonContainer.querySelector('.cbi-button-edit');
				buttonContainer.insertBefore(wakeButton, editButton || buttonContainer.firstChild);
			}

			return defaultButtons;
		};

		return m.render();
	},

	handleWakeup: function(section_id) {
		var name = uci.get('wolultra', section_id, 'name') || section_id;
		var mac = uci.get('wolultra', section_id, 'macaddr');
		var iface = uci.get('wolultra', section_id, 'maceth') || 'br-lan';

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
				_('Wake Host'), ': ', name, ' (', mac, ')',
				E('br'), message
			]), level);
		}).catch(function(err) {
			ui.addNotification(null, E('p', _('Wake command failed: %s.').format(err.message || err)), 'error');
		});
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		}).then(function() {
			return L.resolveDefault(callSync(), null).then(function(result) {
				if (!result || !result.success)
					ui.addNotification(null, E('p', _('Failed to update scheduled wake tasks.')), 'error');
			});
		});
	}
});
