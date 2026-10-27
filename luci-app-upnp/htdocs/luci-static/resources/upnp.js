'use strict';
'require baseclass';
'require rpc';
'require ui';

const callGetStatus = rpc.declare({
	object: 'luci.upnp',
	method: 'get_status',
	expect: { }
});

const callDeleteRule = rpc.declare({
	object: 'luci.upnp',
	method: 'delete_rule',
	params: [ 'token' ],
	expect: { result: 'Invalid response' }
});

function formatExpiry(seconds) {
	seconds = Math.max(0, Math.floor(+seconds || 0));
	const hours = Math.floor(seconds / 3600);
	const minutes = Math.floor(seconds % 3600 / 60);
	const remainder = seconds % 60;
	const pad = value => String(value).padStart(2, '0');
	return hours ? `${hours}h ${pad(minutes)}m ${pad(remainder)}s` :
		minutes ? `${minutes}m ${pad(remainder)}s` : seconds ? `${seconds}s` : '';
}

function getStatus() {
	return callGetStatus().catch(error => ({ rules: [], error: error.message }));
}

function updateTable(table, status) {
	if (table.upnpBusy)
		return;
	const rules = status?.rules;
	const rows = (Array.isArray(rules) ? rules : []).map(rule => [
		'%h'.format(rule.host_hint || _('Unknown')),
		rule.intaddr,
		rule.intport,
		rule.extport,
		rule.proto,
		formatExpiry(rule.expires),
		'%h'.format(rule.descr || ''),
		E('button', {
			'class': 'btn cbi-button-remove',
			'disabled': !L.hasViewPermission() || null,
			'click': ev => deleteRule(table, rule.token, ev)
		}, [ _('Delete') ])
	]);
	cbi_update_table(table, rows, E('em', status?.error ?
		_('Failed to load port mappings: %s').format(status.error) : _('There are no active port maps.')));
}

function deleteRule(table, token, ev) {
	const button = ev.currentTarget;
	if (table.upnpBusy)
		return;
	table.upnpBusy = true;
	button.classList.add('spinning');
	button.disabled = true;
	button.blur();
	return callDeleteRule(token).then(result => {
		if (result !== 'OK')
			throw new Error(result);
		return getStatus();
	}).then(status => {
		table.upnpBusy = false;
		updateTable(table, status);
	}).catch(error => {
		ui.addNotification(null, E('p', _('Failed to delete port mapping: %s').format(error.message)));
	}).finally(() => {
		table.upnpBusy = false;
		button.classList.remove('spinning');
		button.disabled = !L.hasViewPermission();
	});
}

return baseclass.extend({
	getStatus: getStatus,
	updateTable: updateTable,

	renderTable: function(status) {
		const table = E('table', { 'class': 'table cbi-section-table upnp-status-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Client Name')),
				E('th', { 'class': 'th' }, _('Client Address')),
				E('th', { 'class': 'th' }, _('Client Port')),
				E('th', { 'class': 'th' }, _('External Port')),
				E('th', { 'class': 'th' }, _('Protocol')),
				E('th', { 'class': 'th right' }, _('Expires')),
				E('th', { 'class': 'th' }, _('Description')),
				E('th', { 'class': 'th cbi-section-actions' }, '')
			])
		]);
		updateTable(table, status);
		return table;
	}
});
