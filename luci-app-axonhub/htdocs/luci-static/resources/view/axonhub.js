'use strict';
'require dom';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var callStatus = rpc.declare({
	object: 'luci.axonhub',
	method: 'status',
	expect: { '': {} }
});

var callInfo = rpc.declare({
	object: 'luci.axonhub',
	method: 'info',
	expect: { '': {} }
});

var callAction = rpc.declare({
	object: 'luci.axonhub',
	method: 'action',
	params: [ 'action' ],
	expect: { '': {} }
});

var callLog = rpc.declare({
	object: 'luci.axonhub',
	method: 'log',
	expect: { '': {} }
});

var callCronSync = rpc.declare({
	object: 'luci.axonhub',
	method: 'cron',
	expect: { '': {} }
});

var statusNode;

function formatBytes(bytes) {
	bytes = Number(bytes || 0);

	if (bytes >= 1024 * 1024 * 1024)
		return '%.1f GiB'.format(bytes / 1024 / 1024 / 1024);
	if (bytes >= 1024 * 1024)
		return '%.1f MiB'.format(bytes / 1024 / 1024);

	return '%.1f KiB'.format(bytes / 1024);
}

function managementUrl() {
	var host = window.location.hostname;
	var port = uci.get('axonhub', 'main', 'port') || '9069';

	if (port === 'auto')
		port = '9069';

	if (host.indexOf(':') >= 0 && host.charAt(0) !== '[')
		host = '[' + host + ']';

	return 'http://' + host + ':' + port + '/';
}

function notifyError(message) {
	ui.addNotification(null, E('p', message), 'error');
}

function runServiceAction(action, button) {
	if (button)
		button.disabled = true;

	return callAction(action).then(function(result) {
		if (!result || !result.success)
			throw new Error(result && result.message || _('Service action failed with code %s.').format(result && result.code));

		return new Promise(function(resolve) {
			window.setTimeout(resolve, 800);
		});
	}).then(function() {
		return updateStatus();
	}).catch(function(err) {
		notifyError(_('Service action failed: %s.').format(err.message || err));
	}).finally(function() {
		if (button)
			button.disabled = false;
	});
}

function actionButton(label, style, action) {
	return E('button', {
		'type': 'button',
		'class': 'btn cbi-button cbi-button-' + style,
		'click': function(ev) {
			ev.preventDefault();
			return runServiceAction(action, ev.currentTarget);
		}
	}, [ label ]);
}

function showLogs() {
	return callLog().then(function(result) {
		var content = result && result.log || _('No AxonHub log entries were found.');

		ui.showModal(_('AxonHub Log'), [
			E('pre', {
				'style': 'max-height:60vh;overflow:auto;white-space:pre;word-break:normal;overflow-wrap:normal'
			}, [ content ]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'type': 'button',
					'class': 'btn',
					'click': ui.hideModal
				}, [ _('Close') ])
			])
		]);
	}).catch(function(err) {
		notifyError(_('Unable to read logs: %s.').format(err.message || err));
	});
}

function renderStatus(status) {
	var enabled = uci.get('axonhub', 'main', 'enabled') === '1';
	var running = !!(status && status.running);
	var unmanaged = !!(status && status.unmanaged);
	var exists = !!(status && status.exists);
	var details = [];
	var buttons = [];

	if (running) {
		if (status.pid)
			details.push(_('PID %s').format(status.pid));
		if (status.cpu)
			details.push(_('CPU %s').format(status.cpu));
		if (status.memory)
			details.push(_('MEM %s').format(status.memory));

		buttons.push(E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
					ev.preventDefault();
					window.open(managementUrl(), '_blank', 'noopener,noreferrer');
				}
			}, [ _('Open AxonHub') ]));
		if (!unmanaged)
			buttons.push(actionButton(_('Restart'), 'reload', 'restart'));
	}
	else if (exists && enabled) {
		buttons.push(actionButton(_('Start'), 'apply', 'start'));
	}

	buttons.push(E('button', {
		'type': 'button',
		'class': 'btn cbi-button',
		'click': function(ev) {
			ev.preventDefault();
			return showLogs();
		}
	}, [ _('View Log') ]));

	return E('div', {}, [
		E('div', { 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;min-height:32px' }, [
			E('strong', {
				'style': 'color:' + (unmanaged ? '#a65f00' : (running ? '#2d8a34' : '#c33'))
			}, [ unmanaged ? _('Running (unmanaged)') : (running ? _('Running') : _('Not running')) ]),
			details.length ? E('span', {}, [ '(' + details.join(', ') + ')' ]) : '',
			!exists ? E('span', {}, [ _('The AxonHub binary is missing.') ]) : '',
			!running && exists && !enabled ? E('span', {}, [ _('Enable the service and save the configuration to start it.') ]) : ''
		]),
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin-top:10px' }, buttons)
	]);
}

function getStatus() {
	return Promise.all([
		L.resolveDefault(callStatus(), {}),
		L.resolveDefault(callServiceList('axonhub'), {})
	]).then(function(data) {
		var status = data[0] || {};
		var services = data[1] || {};
		var instance = services.axonhub && services.axonhub.instances && services.axonhub.instances.axonhub;
		var processRunning = !!status.running;
		var managedRunning = !!(instance && instance.running);

		status.unmanaged = processRunning && !managedRunning;
		status.running = managedRunning || processRunning;

		if (instance && instance.pid)
			status.pid = instance.pid;

		return status;
	});
}

function updateStatus() {
	if (!statusNode)
		return Promise.resolve();

	return getStatus().then(function(status) {
		dom.content(statusNode, renderStatus(status));
	});
}

function renderStatusSection() {
	statusNode = E('div', {}, [ _('Collecting data...') ]);
	poll.add(updateStatus, 5);
	updateStatus();

	return E('div', { 'class': 'cbi-section' }, [ statusNode ]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callInfo(), {}),
			uci.load('axonhub')
		]);
	},

	render: function(data) {
		var info = data[0] || {};
		var mounts = L.toArray(info.mounts);
		var defaultDataDir = mounts.length
			? mounts[0].path.replace(/\/$/, '') + '/axonhub'
			: '/etc/axonhub';
		var m, s, o;

		m = new form.Map('axonhub', _('AxonHub'),
			_('Native AxonHub service and management interface. — AI Edition') +
			(info.version ? ' ' + _('Installed version: %s').format(info.version) : ''));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = renderStatusSection;

		s = m.section(form.NamedSection, 'main', 'axonhub', _('Service Settings'));
		s.addremove = false;
		s.anonymous = true;
		s.tab('general', _('General'));
		s.tab('resources', _('Resources'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'port', _('Listen port'),
			_('A free port is selected randomly on first installation. The saved value remains unchanged after restarts.'));
		o.default = '9069';
		o.placeholder = '9069';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'data_dir', _('Database and settings directory'),
			_('Changing this path starts a separate instance unless the existing database is moved while AxonHub is stopped.'));
		o.default = defaultDataDir;
		o.rmempty = false;

		if (!mounts.length)
			o.value('/etc/axonhub', '/etc/axonhub');

		mounts.forEach(function(mount) {
			var path = mount.path.replace(/\/$/, '') + '/axonhub';
			var label = _('%s (%s total, %s free, %s)').format(
				path, formatBytes(mount.total), formatBytes(mount.free), mount.type || 'unknown');

			o.value(path, label);
		});

		o = s.taboption('general', form.Button, '_refresh_storage', _('Refresh storage locations'));
		o.inputtitle = _('Refresh');
		o.inputstyle = 'reload';
		o.onclick = function() {
			window.location.reload();
		};

		o = s.taboption('resources', form.ListValue, 'memory_limit', _('Go memory limit'),
			_('A soft runtime limit that leaves memory available for routing and other services.'));
		o.value('256MiB', '256 MiB');
		o.value('384MiB', '384 MiB');
		o.value('512MiB', '512 MiB');
		o.value('768MiB', '768 MiB');
		o.value('1GiB', '1 GiB');
		o.default = '512MiB';
		o.rmempty = false;

		o = s.taboption('resources', form.ListValue, 'gomaxprocs', _('CPU threads'));
		o.value('1');
		o.value('2');
		o.value('3');
		o.value('4');
		o.default = '2';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'max_open_conns', _('Maximum database connections'));
		o.default = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'max_idle_conns', _('Maximum idle database connections'));
		o.default = '5';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'log_level', _('Log level'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warn', _('Warning'));
		o.value('error', _('Error'));
		o.default = 'info';
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'log_to_syslog', _('Write logs to system log'),
			_('Disabled by default because AxonHub can produce a large volume of logs.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'log_cleanup_schedule', _('Log cleanup schedule'),
			_('Clear the dedicated AxonHub log at 03:00 on the selected calendar schedule. System log entries are never cleared.'));
		o.value('disabled', _('Disabled'));
		o.value('daily', _('Every day'));
		o.value('weekly', _('Every week'));
		o.value('monthly', _('Every month'));
		o.default = 'daily';
		o.rmempty = false;
		o.depends('log_to_syslog', '0');

		return m.render();
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		}).then(function() {
			return L.resolveDefault(callCronSync(), null).then(function(result) {
				if (!result || !result.success)
					notifyError(_('Failed to update the log cleanup schedule.'));
			});
		});
	}
});
