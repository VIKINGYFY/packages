
let invalid_mac = methods.wake.call({ args: {
	iface: 'br-lan',
	mac: 'not-a-mac'
} });
let invalid_iface = methods.wake.call({ args: {
	iface: 'br-lan;reboot',
	mac: '00:11:22:33:44:55'
} });
let missing_binary = methods.wake.call({ args: {
	iface: 'br-lan',
	mac: '00:11:22:33:44:55'
} });
let sync = methods.sync.call();

print({
	invalid_mac: invalid_mac,
	invalid_iface: invalid_iface,
	missing_binary: missing_binary,
	sync: sync
});
