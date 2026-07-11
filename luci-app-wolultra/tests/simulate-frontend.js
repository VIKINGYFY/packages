'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(process.env.WOLULTRA_VIEW || path.join(__dirname,
	'../htdocs/luci-static/resources/view/wolultra.js'), 'utf8');
const rpcCalls = [];
const invoked = [];
const sections = [];
const config = {
	client1: {
		name: 'Desktop',
		macaddr: '00:11:22:33:44:55',
		maceth: 'br-lan',
		scheduled: '1',
		minute: '30',
		hour: '7',
		day: '*',
		month: '*',
		weeks: '1'
	},
	client2: {
		name: 'NAS',
		macaddr: '00:11:22:33:44:66',
		maceth: 'br-lan',
		scheduled: '0'
	}
};

String.prototype.format = function() {
	let index = 0;
	const args = arguments;
	return this.replace(/%[sd]/g, () => String(args[index++]));
};

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function Option(type, name, title) {
	this.type = type;
	this.name = name;
	this.title = title;
	this.dependencies = [];
	this.values = [];
}
Option.prototype.value = function(value, label) {
	this.values.push([ value, label ]);
};
Option.prototype.depends = function(name, value) {
	this.dependencies.push([ name, value ]);
};

function Section(type) {
	this.type = type;
	this.options = [];
}
Section.prototype.tab = function() {};
Section.prototype.taboption = function(tab, type, name, title) {
	const option = new Option(type, name, title);
	option.tab = tab;
	this.options.push(option);
	return option;
};

function Map() {}
Map.prototype.section = function(type) {
	const section = new Section(type);
	sections.push(section);
	return section;
};
Map.prototype.render = function() {
	return Promise.resolve();
};

function element() {
	return {
		querySelector: function() { return null; }
	};
}

const form = {
	Map: Map,
	TypedSection: function TypedSection() {},
	GridSection: function GridSection() {},
	Value: function Value() {},
	Flag: function Flag() {},
	DummyValue: function DummyValue() {}
};
form.GridSection.prototype.renderRowActions = function() {
	return element();
};

const rpc = {
	declare: function(spec) {
		rpcCalls.push(spec);
		return function() {
			invoked.push([ spec.method, ...arguments ]);
			if (spec.method === 'wake')
				return Promise.resolve({ code: 0, stdout: 'sent' });
			if (spec.method === 'sync')
				return Promise.resolve({ success: true });
			return Promise.resolve({});
		};
	}
};

const ui = {
	changes: {
		apply: function() {
			invoked.push([ 'apply' ]);
			return Promise.resolve();
		}
	},
	addNotification: function() {},
	createHandlerFn: function(context, fn) { return fn.bind(context); }
};

const uci = {
	load: function() { return Promise.resolve(); },
	get: function(packageName, section, option) {
		return config[section] && config[section][option];
	}
};

const L = {
	resolveDefault: function(promise, fallback) {
		return Promise.resolve(promise).catch(() => fallback);
	},
	sortedKeys: function(object) { return Object.keys(object).sort(); },
	toArray: function(value) { return value == null ? [] : [].concat(value); },
	bind: function(fn, context) {
		return fn.bind(context, ...Array.prototype.slice.call(arguments, 2));
	}
};

const moduleFactory = new Function('form', 'rpc', 'ui', 'uci', 'view',
	'widgets', 'L', 'E', '_', source);
const module = moduleFactory(
	form,
	rpc,
	ui,
	uci,
	{ extend: function(object) { return object; } },
	{ DeviceSelect: function DeviceSelect() {} },
	L,
	element,
	function(text) { return text; }
);

(async function() {
	await module.render([ {
		'00:11:22:33:44:66': { name: 'Laptop' },
		'00:11:22:33:44:77': { ipv4: [ '192.168.1.77' ] }
	} ]);

	assert(rpcCalls.some(call => call.object === 'luci.wolultra' && call.method === 'wake'),
		'wake RPC is declared');
	assert(rpcCalls.some(call => call.object === 'luci.wolultra' && call.method === 'sync'),
		'sync RPC is declared');
	assert(!rpcCalls.some(call => call.object === 'luci.wolultra' && call.method === 'status'),
		'status RPC is not declared');
	assert(!sections.some(section => section.type === form.TypedSection),
		'status section is removed');

	const clients = sections.find(section => section.type === form.GridSection);
	assert(clients, 'client grid exists');
	assert(clients.addremove === true && clients.sortable === true,
		'clients can be added, removed, and reordered');
	const names = clients.options.map(option => option.name);
	assert(JSON.stringify(names) === JSON.stringify([
		'name', 'macaddr', 'maceth', 'scheduled', '_schedule', 'minute', 'hour', 'day', 'month', 'weeks'
	]), 'all unified client options are present and no global switch exists');

	const scheduled = clients.options.find(option => option.name === 'scheduled');
	assert(scheduled.default === '0' && scheduled.rmempty === false && scheduled.modalonly === true,
		'scheduled wake is an independent per-client switch in the edit dialog');
	for (const name of [ 'name', 'macaddr', 'maceth', 'scheduled' ])
		assert(clients.options.find(option => option.name === name).modalonly !== false,
			`${name} is available in the add/edit dialog`);
	const schedule = clients.options.find(option => option.name === '_schedule');
	assert(schedule.type === form.DummyValue && schedule.modalonly === false,
		'scheduled wake column is table-only');
	assert(schedule.textvalue('client1') === '30 7 * * 1',
		'enabled client shows its five-field cron expression');
	assert(schedule.textvalue('client2') === 'Disabled',
		'disabled client shows Disabled');
	assert(clients.options.find(option => option.name === 'name').rmempty === false,
		'client name is required');
	const macOption = clients.options.find(option => option.name === 'macaddr');
	assert(macOption.datatype === 'macaddr',
		'MAC address uses LuCI MAC validation');
	assert(JSON.stringify(macOption.values) === JSON.stringify([
		[ '00:11:22:33:44:66', '00:11:22:33:44:66 (Laptop)' ],
		[ '00:11:22:33:44:77', '00:11:22:33:44:77 (192.168.1.77)' ]
	]), 'existing clients are offered in the MAC selector');
	assert(clients.options.find(option => option.name === 'maceth').default === 'br-lan',
		'network interface defaults to br-lan');

	const cronCases = {
		minute: [ '0', '59', '60', '0' ],
		hour: [ '0', '23', '24', '0' ],
		day: [ '1', '31', '32', '*' ],
		month: [ '1', '12', '13', '*' ],
		weeks: [ '0', '6', '7', '*' ]
	};
	const cronTitles = {
		minute: 'Minute (0-59)',
		hour: 'Hour (0-23)',
		day: 'Day (1-31)',
		month: 'Month (1-12)',
		weeks: 'Week (0-6)'
	};
	for (const option of clients.options.filter(option => option.validate)) {
		const values = cronCases[option.name];
		assert(option.dependencies.some(dep => dep[0] === 'scheduled' && dep[1] === '1'),
			`${option.name} depends on the per-client scheduled switch`);
		assert(option.modalonly === true, `${option.name} is kept in the edit dialog`);
		assert(option.title === cronTitles[option.name], `${option.name} shows its accepted range`);
		assert(option.default === values[3], `${option.name} has the expected default`);
		assert(option.validate('client1', '*') === true, `${option.name} accepts wildcard`);
		assert(option.validate('client1', values[0]) === true, `${option.name} accepts lower boundary`);
		assert(option.validate('client1', values[1]) === true, `${option.name} accepts upper boundary`);
		assert(option.validate('client1', values[2]) !== true, `${option.name} rejects out of range`);
		assert(option.validate('client1', '1a') !== true, `${option.name} rejects non-numeric values`);
	}

	await module.handleWakeup('client1');
	const wake = invoked.find(call => call[0] === 'wake');
	assert(wake && wake[1] === 'br-lan' && wake[2] === '00:11:22:33:44:55',
		'immediate wake uses the selected client interface and MAC');

	module.handleSave = function() {
		invoked.push([ 'save' ]);
		return Promise.resolve();
	};
	await module.handleSaveApply(null, '1');
	const saveIndex = invoked.findIndex(call => call[0] === 'save');
	const applyIndex = invoked.findIndex(call => call[0] === 'apply');
	const syncIndex = invoked.findIndex(call => call[0] === 'sync');
	assert(saveIndex < applyIndex && applyIndex < syncIndex,
		'save/apply synchronizes cron only after UCI changes are applied');

	console.log('simulate-frontend: all assertions passed');
})().catch(error => {
	console.error(error.stack || error);
	process.exit(1);
});
