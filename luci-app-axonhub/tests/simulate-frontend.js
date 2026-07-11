'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(process.env.AXONHUB_VIEW || path.join(__dirname,
	'../htdocs/luci-static/resources/view/axonhub.js'), 'utf8');
const sections = [];

String.prototype.format = function() {
	let index = 0;
	const args = arguments;
	return this.replace(/%(?:\.(\d+))?([sdf])/g, function(match, precision, type) {
		const value = args[index++];
		return type === 'f' && precision != null
			? Number(value).toFixed(Number(precision))
			: String(value);
	});
};

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function Option(type, name, title) {
	this.type = type;
	this.name = name;
	this.title = title;
	this.values = [];
}
Option.prototype.value = function(value, label) {
	this.values.push([ value, label == null ? value : label ]);
};
Option.prototype.depends = function() {};

function Section(type) {
	this.type = type;
	this.options = [];
	this.tabs = [];
}
Section.prototype.tab = function(name, title) { this.tabs.push([ name, title ]); };
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
Map.prototype.render = function() { return Promise.resolve(); };

const form = {
	Map: Map,
	TypedSection: function TypedSection() {},
	NamedSection: function NamedSection() {},
	Flag: function Flag() {},
	Value: function Value() {},
	ListValue: function ListValue() {},
	Button: function Button() {}
};
const rpc = {
	declare: function() {
		return function() { return Promise.resolve({}); };
	}
};
const L = {
	resolveDefault: function(value) { return Promise.resolve(value); },
	toArray: function(value) { return value == null ? [] : [].concat(value); }
};
const moduleFactory = new Function('dom', 'form', 'poll', 'rpc', 'ui', 'uci', 'view',
	'L', 'E', '_', 'window', source);
const module = moduleFactory(
	{ content: function() {} },
	form,
	{ add: function() {} },
	rpc,
	{ changes: { apply: function() { return Promise.resolve(); } }, addNotification: function() {} },
	{ load: function() { return Promise.resolve(); }, get: function() {} },
	{ extend: function(object) { return object; } },
	L,
	function() { return {}; },
	function(text) { return text; },
	{ location: { hostname: 'router' }, setTimeout: setTimeout }
);

(async function() {
	await module.render([ {
		version: 'test',
		mounts: [
			{ path: '/mnt/large', total: 137438953472, free: 107374182400, type: 'ext4' },
			{ path: '/mnt/small', total: 34359738368, free: 17179869184, type: 'ext4' }
		]
	} ]);

	const settings = sections.find(section => section.type === form.NamedSection);
	assert(settings, 'AxonHub settings section exists');
	assert(settings.tabs.some(tab => tab[0] === 'advanced' && tab[1] === 'Advanced'),
		'advanced settings use the shared tab name');
	assert(!settings.options.some(option => option.name === 'listen_addr'),
		'listen address entry is removed');

	const dataDir = settings.options.find(option => option.name === 'data_dir');
	assert(dataDir && dataDir.type === form.ListValue,
		'database and settings directory is a strict dropdown');
	assert(dataDir.default === '/mnt/large/axonhub',
		'largest scanned filesystem is selected by default');
	assert(JSON.stringify(dataDir.values.map(value => value[0])) === JSON.stringify([
		'/mnt/large/axonhub', '/mnt/small/axonhub'
	]), 'dropdown contains scanned paths only');
	assert(!dataDir.values.some(value => /Recommended/.test(value[1])),
		'dropdown does not contain a recommended pseudo-entry');
	const refresh = settings.options.find(option => option.name === '_refresh_storage');
	assert(refresh && refresh.type === form.Button && refresh.inputstyle === 'reload' && refresh.inputtitle === 'Refresh',
		'storage locations have a refresh button');
	const cleanup = settings.options.find(option => option.name === 'log_cleanup_schedule');
	assert(cleanup.default === 'daily' && JSON.stringify(cleanup.values.map(value => value[0])) ===
		JSON.stringify([ 'disabled', 'daily', 'weekly', 'monthly' ]),
		'log cleanup uses the shared values and default');

	sections.length = 0;
	await module.render([ { mounts: [] } ]);
	const fallback = sections.find(section => section.type === form.NamedSection)
		.options.find(option => option.name === 'data_dir');
	assert(fallback.default === '/etc/axonhub' && fallback.values[0][0] === '/etc/axonhub',
		'/etc/axonhub is used only when no persistent path is scanned');

	console.log('simulate-frontend: all assertions passed');
})().catch(error => {
	console.error(error.stack || error);
	process.exit(1);
});
