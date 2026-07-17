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
	object: 'luci.gecoosac',
	method: 'status',
	expect: { '': {} }
});

var callAction = rpc.declare({
	object: 'luci.gecoosac',
	method: 'action',
	params: [ 'action' ],
	expect: { '': {} }
});

var callLog = rpc.declare({
	object: 'luci.gecoosac',
	method: 'log',
	expect: { '': {} }
});

var callCronSync = rpc.declare({
	object: 'luci.gecoosac',
	method: 'cron',
	expect: { '': {} }
});

var callClearUpload = rpc.declare({
	object: 'luci.gecoosac',
	method: 'clear_upload',
	expect: { '': {} }
});

var statusNode;

function managementUrl() {
	var host = window.location.hostname;
	var port = uci.get('gecoosac', 'config', 'port') || '60650';

	if (port === 'auto')
		port = '60650';

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
		var content = result && result.log || _('No Gecoos AC log entries were found.');

		ui.showModal(_('Gecoos AC Log'), [
			E('pre', {
				'style': 'max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-word'
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
	var enabled = uci.get('gecoosac', 'config', 'enabled') === '1';
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
		}, [ _('Open Gecoos AC') ]));
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
			!exists ? E('span', {}, [ _('The Gecoos AC binary is missing.') ]) : '',
			!running && exists && !enabled ? E('span', {}, [ _('Enable the service and save the configuration to start it.') ]) : ''
		]),
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin-top:10px' }, buttons)
	]);
}

function getStatus() {
	return Promise.all([
		L.resolveDefault(callStatus(), {}),
		L.resolveDefault(callServiceList('gecoosac'), {})
	]).then(function(data) {
		var status = data[0] || {};
		var services = data[1] || {};
		var instance = services.gecoosac && services.gecoosac.instances && services.gecoosac.instances.gecoosac;
		var processRunning = !!status.running;
		var managedRunning = !!(instance && instance.running);

		status.unmanaged = processRunning && !managedRunning;
		status.running = managedRunning || processRunning;

		if (!status.pid && instance && instance.pid)
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

function validateDirectory(sectionId, value) {
	if (!value || !/^\/[A-Za-z0-9_./-]+$/.test(value))
		return _('Enter an absolute path using letters, numbers, dot, underscore, slash or hyphen.');

	if (/(^|\/)\.\.(\/|$)/.test(value) || value === '/')
		return _('The directory must not be the root directory or contain parent-directory components.');

	return true;
}

function validateDatabaseDirectory(sectionId, value) {
	var valid = validateDirectory(sectionId, value);

	if (valid !== true)
		return valid;

	if (/^\/(tmp|var|rom|proc|sys|dev)(\/|$)/.test(value))
		return _('Select a persistent writable database directory outside volatile or system paths.');

	return true;
}

return view.extend({
	load: function() {
		return uci.load('gecoosac');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('gecoosac', _('Gecoos AC'),
			_('Native Gecoos AC service and management interface. Default web password: admin. — AI Edition'));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = renderStatusSection;

		s = m.section(form.NamedSection, 'config', 'gecoosac', _('Service Settings'));
		s.addremove = false;
		s.anonymous = true;
		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'port', _('Listen port'),
			_('A free port is selected randomly on first installation. The saved value remains unchanged after restarts.'));
		o.default = '60650';
		o.placeholder = '60650';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'upload_dir', _('Firmware directory'),
			_('Directory used to store AP firmware uploaded for upgrades.'));
		o.default = '/tmp/gecoosac/upload/';
		o.placeholder = '/tmp/gecoosac/upload/';
		o.rmempty = false;
		o.validate = validateDirectory;

		o = s.taboption('general', form.Value, 'db_dir', _('Database directory'),
			_('Persistent directory used to store the controller configuration database.'));
		o.default = '/etc/gecoosac/';
		o.placeholder = '/etc/gecoosac/';
		o.rmempty = false;
		o.validate = validateDatabaseDirectory;

		o = s.taboption('general', form.Button, '_clear_upload', _('Clear firmware directory'));
		o.inputstyle = 'remove';
		o.onclick = function(sectionId) {
			var opt = L.toArray(m.lookupOption('upload_dir', sectionId))[0];
			var savedPath = uci.get('gecoosac', 'config', 'upload_dir') || '/tmp/gecoosac/upload/';
			var formPath = (opt ? opt.formvalue(sectionId) : null) || savedPath;

			if (formPath !== savedPath) {
				ui.addNotification(null, E('p', _('Save and apply the firmware directory before clearing it.')), 'error');
				return Promise.resolve();
			}

			return callClearUpload().then(function(result) {
				if (result && result.success) {
					ui.addNotification(null, E('p', _('Firmware directory cleaned. Removed %d entries.').format(result.deleted || 0)), 'info');
				}
				else {
					var details = result && (result.message || L.toArray(result.errors).join('; ')) || _('Unknown error');
					ui.addNotification(null, E('p', _('Failed to clear firmware directory: %s.').format(details)), 'error');
				}
			}).catch(function(err) {
				ui.addNotification(null, E('p', _('Failed to clear firmware directory: %s.').format(err.message || err)), 'error');
			});
		};

		o = s.taboption('advanced', form.Flag, 'log', _('Enable logging'),
			_('Write Gecoos AC output to a dedicated log file in the database directory. Log contents are automatically deleted when the file exceeds the selected size limit.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'log_max_size', _('Log size limit'));
		[ '10', '20', '30', '40', '50' ].forEach(function(size) {
			o.value(size, size + ' MiB');
		});
		o.default = '20';
		o.rmempty = false;
		o.depends('log', '1');

		o = s.taboption('advanced', form.ListValue, 'log_cleanup_schedule', _('Log cleanup schedule'),
			_('Clear the dedicated Gecoos AC log at 03:00 on the selected calendar schedule.'));
		o.value('disabled', _('Disabled'));
		o.value('daily', _('Every day'));
		o.value('weekly', _('Every week'));
		o.value('monthly', _('Every month'));
		o.default = 'daily';
		o.rmempty = false;
		o.depends('log', '1');

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
