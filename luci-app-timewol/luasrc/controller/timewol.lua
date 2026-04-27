local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"

local M = {}

function M.index()
	if not fs.access("/etc/config/timewol") then
		return
	end

	entry({"admin", "control"}, firstchild(), _("Control"), 44).dependent = false
	local page = entry({"admin", "control", "timewol"}, cbi("timewol"), _("Timed WOL"))
	page.order = 95
	page.dependent = true
	page.acl_depends = { "luci-app-timewol" }
	entry({"admin", "control", "timewol", "status"}, call("status")).leaf = true
end

function M.status()
	local e = {
		status = sys.call("cat /etc/crontabs/root | grep etherwake >/dev/null") == 0
	}
	http.prepare_content("application/json")
	http.write_json(e)
end

return M