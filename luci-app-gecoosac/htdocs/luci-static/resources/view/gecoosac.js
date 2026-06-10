'use strict';
'require dom';
'require form';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';

var callStatus = rpc.declare({
	object: 'luci.gecoosac',
	method: 'status',
	expect: { '': {} }
});

var callClearUpload = rpc.declare({
	object: 'luci.gecoosac',
	method: 'clear_upload',
	params: [ 'path' ],
	expect: { '': {} }
});

function isTrue(value) {
	return value === true || value === '1' || value === 'true' || value === 'yes' || value === 'on';
}

function mgmtUrl() {
	var isonlyoneprot = uci.get('gecoosac', 'config', 'isonlyoneprot') || '1';
	var https = uci.get('gecoosac', 'config', 'https') || '0';
	var port = uci.get('gecoosac', 'config', 'port') || '60650';
	var scheme = 'http://';

	if (isonlyoneprot === '0') {
		port = uci.get('gecoosac', 'config', 'm_port') || '8080';

		if (isTrue(https))
			scheme = 'https://';
	}

	return scheme + window.location.hostname + ':' + port;
}

function renderStatus(running) {
	var statusNode = E('span', {
		'style': 'font-weight:bold;font-style:italic;color:%s'.format(running ? 'green' : 'red')
	}, [ _('Gecoos AC'), '：', running ? _('Running') : _('Not running') ]);

	if (running) {
		return [
			statusNode,
			' ',
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					window.open(mgmtUrl(), '_blank', 'noopener');
				}
			}, [ _('Open the mgmt page') ])
		];
	}

	return statusNode;
}

function getServiceStatus() {
	return L.resolveDefault(callStatus(), {});
}

function getRunningStatus() {
	return getServiceStatus().then(function(status) {
		return !!(status && status.running);
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

return view.extend({
	load: function() {
		return Promise.all([
			getServiceStatus(),
			uci.load('gecoosac')
		]);
	},

	render: function(data) {
		var status = data[0] || {};
		var desc = _('Batch management Gecoos AP, Default password: admin') + '<br />' +
			(status.exists
				? _('The current AC version %s, only supports AP %s and above.').format('2.2', '7.6')
				: _('The AC program does not exist, please check.'));
		var m, s, o;

		m = new form.Map('gecoosac', _('Gecoos AC'), desc);

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = renderStatusSection;

		s = m.section(form.NamedSection, 'config', 'gecoosac', _('Global Settings'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enabled AC'));
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Set interface port'));
		o.placeholder = '60650';
		o.default = '60650';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Flag, 'isonlyoneprot', _('Single Port Mode'),
			_('Do not enable the independent management port, only use one port for management.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'm_port', _('Set management port'));
		o.placeholder = '8080';
		o.default = '8080';
		o.datatype = 'port';
		o.depends('isonlyoneprot', '0');

		o = s.option(form.Flag, 'https', _('Enable HTTPS service'),
			_('A certificate file must be specified, otherwise it will fail to start.'));
		o.default = '0';
		o.depends('isonlyoneprot', '0');

		o = s.option(form.Value, 'crt_file', _('Specify crt certificate file'));
		o.placeholder = '/etc/gecoosac/tls/1.crt';
		o.default = '/etc/gecoosac/tls/1.crt';
		o.depends({ isonlyoneprot: '0', https: '1' });

		o = s.option(form.Value, 'key_file', _('Specify key certificate file'));
		o.placeholder = '/etc/gecoosac/tls/1.key';
		o.default = '/etc/gecoosac/tls/1.key';
		o.depends({ isonlyoneprot: '0', https: '1' });

		o = s.option(form.Value, 'upload_dir', _('Upload dir path'), _('The path to upload AP upgrade firmware'));
		o.placeholder = '/tmp/gecoosac/upload/';
		o.default = '/tmp/gecoosac/upload/';
		o.rmempty = false;

		o = s.option(form.Value, 'db_dir', _('Database dir path'), _('The path to store the config database'));
		o.placeholder = '/etc/gecoosac/';
		o.default = '/etc/gecoosac/';
		o.rmempty = false;

		o = s.option(form.Flag, 'log', _('Enable Log'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Button, '_clear_upload', _('Clear Upload Directory'));
		o.inputstyle = 'remove';
		o.onclick = function(section_id) {
			var opt = L.toArray(m.lookupOption('upload_dir', section_id))[0];
			var path = (opt ? opt.formvalue(section_id) : null) ||
				uci.get('gecoosac', 'config', 'upload_dir') ||
				'/tmp/gecoosac/upload/';

			return callClearUpload(path).then(function(res) {
				if (res && res.success) {
					ui.addNotification(null, E('p', _('Upload directory cleaned. Removed %d entries.').format(res.deleted || 0)), 'info');
				}
				else {
					var details = res && (res.message || L.toArray(res.errors).join('; ')) || _('Unknown error');
					ui.addNotification(null, E('p', _('Failed to clear upload directory: %s').format(details)), 'error');
				}
			}).catch(function(err) {
				ui.addNotification(null, E('p', _('Failed to clear upload directory: %s').format(err.message || err)), 'error');
			});
		};

		return m.render();
	}
});
