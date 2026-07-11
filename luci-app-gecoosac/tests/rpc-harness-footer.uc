let outside = test_root + '/outside';
let configured = test_root + '/upload';

let invalid_action = methods.action.call({ args: { action: 'stop' } });
let start_action = methods.action.call({ args: { action: 'start' } });
let clear = methods.clear_upload.call({ args: { path: outside } });
configured_path = '/etc';
let protected = methods.clear_upload.call({ args: {} });

print({
	invalid_action: invalid_action,
	start_action: start_action,
	clear: clear,
	protected: protected
});
