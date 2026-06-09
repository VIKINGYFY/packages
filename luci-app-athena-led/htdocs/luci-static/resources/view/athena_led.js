'use strict';
'require dom';
'require form';
'require poll';
'require rpc';
'require view';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function addChoices(option, choices) {
	for (var i = 0; i < choices.length; i++)
		option.value(choices[i][0], choices[i][1]);

	return option;
}

function renderStatus(running) {
	return E('span', {
		'style': 'font-weight:bold;color:%s'.format(running ? 'green' : 'red')
	}, [ running ? _('Running') : _('Not running') ]);
}

function isServiceRunning(res) {
	var service = res && res.athena_led;
	var instances = (service && service.instances) || {};

	for (var name in instances) {
		if (instances[name].running === true)
			return true;
	}

	return false;
}

function updateStatus(node) {
	return L.resolveDefault(callServiceList('athena_led'), {}).then(function(res) {
		dom.content(node, renderStatus(isServiceRunning(res)));
	});
}

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('athena_led', _('Athena LED Ctrl'), _('JDCloud Athena LED Ctrl'));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			var node = E('span', { 'id': 'athena-led-service-status' }, [ _('Collecting data...') ]);
			var refresh = L.bind(updateStatus, null, node);

			refresh();
			poll.add(refresh, 3);

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Status')),
				E('p', {}, [ _('Service status'), ': ', node ])
			]);
		};

		s = m.section(form.NamedSection, 'config', 'athena_led', _('Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enable', _('Enabled'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'seconds', _('Display interval time'), _('Enable carousel display and set interval time in seconds'));
		o.default = '5';
		o.rmempty = false;
		for (var i = 1; i <= 5; i++)
			o.value(String(i), _('%d seconds').format(i));

		o = s.option(form.ListValue, 'lightLevel', _('Display light level'), _('Display light level desc'));
		o.default = '5';
		o.rmempty = false;
		for (var j = 0; j <= 7; j++)
			o.value(String(j));

		o = s.option(form.MultiValue, 'status', _('Side LED status'), _('side led status desc'));
		o.rmempty = true;
		addChoices(o, [
			[ 'time', _('status time') ],
			[ 'medal', _('status medal') ],
			[ 'upload', _('status upload') ],
			[ 'download', _('status download') ]
		]);

		o = s.option(form.MultiValue, 'option', _('Display Type'), _('Select one or more display modes'));
		o.default = [ 'date', 'timeBlink' ];
		o.rmempty = false;
		addChoices(o, [
			[ 'date', _('Display Type Date') ],
			[ 'time', _('Display Type Time') ],
			[ 'timeBlink', _('Display Type Time Blink') ],
			[ 'temp', _('Display Type temp') ],
			[ 'string', _('Display Type String') ],
			[ 'getByUrl', _('Display Type getByUrl') ]
		]);

		o = s.option(form.Value, 'value', _('Custom Value'), _('Set the custom message to display on the LED screen, Only effective on \'Display Type String\''));
		o.default = 'abcdefghijklmnopqrstuvwxyz0123456789+-*/=.:：℃';
		o.placeholder = _('Enter your message here');
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('Remote text URL'), _('api url for get content des'));
		o.default = 'https://ifconfig.me';
		o.placeholder = _('Enter your api url here');
		o.rmempty = false;

		o = s.option(form.MultiValue, 'tempFlag', _('tempFlag'), _('Select the temperature sensor, Only effective on \'Display Type temp\''));
		o.default = [ '4' ];
		o.rmempty = false;
		addChoices(o, [
			[ '0', _('nss-top') ],
			[ '1', _('nss') ],
			[ '2', _('wcss-phya0') ],
			[ '3', _('wcss-phya1') ],
			[ '4', _('cpu') ],
			[ '5', _('lpass') ],
			[ '6', _('ddrss') ]
		]);

		return m.render();
	}
});
