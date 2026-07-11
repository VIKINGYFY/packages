'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(process.env.GECOOSAC_VIEW || path.join(__dirname,
	'../htdocs/luci-static/resources/view/gecoosac.js'), 'utf8');
const sections = [];
const rpcCalls = [];

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function Option(name, title, description) {
	this.name = name;
	this.title = title;
	this.description = description;
	this.values = [];
}
Option.prototype.value = function(value) { this.values.push(value); };
Option.prototype.depends = function() {};

function Section(type) {
	this.type = type;
	this.options = [];
	this.tabs = [];
}
Section.prototype.tab = function(name, title) { this.tabs.push([ name, title ]); };
Section.prototype.taboption = function(tab, type, name, title, description) {
	const option = new Option(name, title, description);
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
const rpc = { declare: function(spec) { rpcCalls.push(spec); return function() { return Promise.resolve({}); }; } };
const L = {
	resolveDefault: function(value) { return Promise.resolve(value); },
	toArray: function(value) { return value == null ? [] : [].concat(value); }
};
const moduleFactory = new Function('dom', 'form', 'poll', 'rpc', 'ui', 'uci', 'view',
	'L', 'E', '_', 'window', source);
const module = moduleFactory(
	{ content: function() {} }, form, { add: function() {} }, rpc,
	{ changes: { apply: function() { return Promise.resolve(); } }, addNotification: function() {} },
	{ load: function() { return Promise.resolve(); }, get: function() {} },
	{ extend: function(object) { return object; } }, L,
	function() { return {}; }, function(text) { return text; },
	{ location: { hostname: 'router' }, setTimeout: setTimeout }
);

(async function() {
	await module.render();
	const settings = sections.find(section => section.type === form.NamedSection);
	assert(settings.tabs.some(tab => tab[0] === 'advanced' && tab[1] === 'Advanced'),
		'advanced settings use the shared tab name');
	assert(!settings.tabs.some(tab => tab[0] === 'logging'),
		'logging uses the shared advanced settings tab');
	assert(settings.options.find(option => option.name === 'port').title === 'Listen port',
		'port label is Listen port');
	assert(settings.options.find(option => option.name === 'upload_dir').title === 'Firmware directory',
		'upload path label is Firmware directory');
	assert(settings.options.find(option => option.name === '_clear_upload').title === 'Clear firmware directory',
		'cleanup action uses firmware directory terminology');
	const logging = settings.options.find(option => option.name === 'log');
	assert(logging.default === '0' && logging.description.includes('automatically deleted') &&
		!logging.description.includes('hourly'),
		'file logging defaults off and documents automatic size cleanup');
	const logSize = settings.options.find(option => option.name === 'log_max_size');
	assert(logSize.default === '20' && JSON.stringify(logSize.values) ===
		JSON.stringify([ '10', '20', '30', '40', '50' ]),
		'log size limit provides all supported values and defaults to 20 MiB');
	const cleanup = settings.options.find(option => option.name === 'log_cleanup_schedule');
	assert(cleanup.default === 'daily' && JSON.stringify(cleanup.values) ===
		JSON.stringify([ 'disabled', 'daily', 'weekly', 'monthly' ]),
		'log cleanup uses the shared values and default');
	const clearRpc = rpcCalls.find(call => call.object === 'luci.gecoosac' && call.method === 'clear_upload');
	assert(clearRpc && !clearRpc.params,
		'clear upload RPC does not accept a browser-controlled path');
	console.log('simulate-labels: all assertions passed');
})().catch(error => {
	console.error(error.stack || error);
	process.exit(1);
});
