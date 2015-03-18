module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.i18n"
local uci = luci.model.uci.cursor()
local util = require "luci.util"

function index()
	entry({"admin", "services", "splash"}, cbi("commotion-splash/splash_settings"), _("Captive Portal"), 90).dependent=true
  entry({"commotion", "splash"}, template("commotion-splash/splash")).dependent=false

	local e
	
	e = node("splash")
	e.target = call("action_dispatch")

	node("splash", "activate").target = call("action_activate")
	node("splash", "splash").target   = template("commotion-splash/splash")
	node("splash", "blocked").target  = template("commotion-splash/blocked")

	entry({"admin", "status", "splash"}, call("action_status_admin"), _("Client-Splash"))

	local page  = node("splash", "publicstatus")
	page.target = call("action_status_public")
	page.leaf   = true
end

function action_dispatch()
	local uci = luci.model.uci.cursor_state()
	local autoauth = uci:get("luci_splash", "general", "autoauth")
	if autoauth and autoauth == "1" then
		action_activate(true)
		return
	end
	
	local mac = luci.sys.net.ip4mac(luci.http.getenv("REMOTE_ADDR")) or ""
	local access = false

	uci:foreach("luci_splash", "lease", function(s)
		if s.mac and s.mac:lower() == mac then access = true end
	end)
	uci:foreach("luci_splash", "whitelist", function(s)
		if s.mac and s.mac:lower() == mac then access = true end
	end)

	if #mac > 0 and access then
		luci.http.redirect(luci.dispatcher.build_url())
	else
		luci.http.redirect(luci.dispatcher.build_url("splash", "splash"))
	end
end

function blacklist()
	leased_macs = { }
	uci:foreach("luci_splash", "blacklist",
	        function(s) leased_macs[s.mac:lower()] = true
	end)
	return leased_macs
end

function action_activate(is_immediate)
	local ip = luci.http.getenv("REMOTE_ADDR") or "127.0.0.1"
	local mac = luci.sys.net.ip4mac(ip:match("^[\[::ffff:]*(%d+.%d+%.%d+%.%d+)\]*$"))
	local uci_state = require "luci.model.uci".cursor_state()
	local blacklisted = false
	if mac and (luci.http.formvalue("internet.x") or luci.http.formvalue("apps.x") or is_immediate) then
		uci:foreach("luci_splash", "blacklist",
        	        function(s) if s.mac:lower() == mac or s.mac == mac then blacklisted = true end
	        end)
		if blacklisted then	
			luci.http.redirect(luci.dispatcher.build_url("splash" ,"blocked"))
		else
			local redirect_url = uci:get("luci_splash", "general", "redirect_url")
			if luci.http.formvalue("apps") then
				redirect_url = luci.dispatcher.build_url("apps.x")
			end
			if not redirect_url then
				redirect_url = uci_state:get("luci_splash_locations", mac:gsub(':', ''):lower(), "location")
			end
			if not redirect_url then
				redirect_url = 'https://commotionwireless.net'
			end
			remove_redirect(mac:gsub(':', ''):lower())
			os.execute("luci-splash lease "..mac.." >/dev/null 2>&1")
			luci.http.redirect(redirect_url)
		end
	else
		luci.http.redirect(luci.dispatcher.build_url())
	end
end

function action_status_admin()
	local uci = luci.model.uci.cursor_state()
	local macs = luci.http.formvaluetable("save")

	local changes = { 
		whitelist = { },
		blacklist = { },
		lease     = { },
		remove    = { }
	}

	for key, _ in pairs(macs) do
		local policy = luci.http.formvalue("policy.%s" % key)
		local mac    = luci.http.protocol.urldecode(key)

		if policy == "whitelist" or policy == "blacklist" then
			changes[policy][#changes[policy]+1] = mac
		elseif policy == "normal" then
			changes["lease"][#changes["lease"]+1] = mac
		elseif policy == "kicked" then
			changes["remove"][#changes["remove"]+1] = mac
		end
	end

	if #changes.whitelist > 0 then
		os.execute("luci-splash whitelist %s >/dev/null"
			% table.concat(changes.whitelist))
	end

	if #changes.blacklist > 0 then
		os.execute("luci-splash blacklist %s >/dev/null"
			% table.concat(changes.blacklist))
	end

	if #changes.lease > 0 then
		os.execute("luci-splash lease %s >/dev/null"
			% table.concat(changes.lease))
	end

	if #changes.remove > 0 then
		os.execute("luci-splash remove %s >/dev/null"
			% table.concat(changes.remove))
	end

	luci.template.render("admin_status/splash", { is_admin = true })
end

function action_status_public()
	luci.template.render("admin_status/splash", { is_admin = false })
end

function remove_redirect(mac)
	local mac = mac:lower()
	mac = mac:gsub(":", "")
	local uci = require "luci.model.uci".cursor_state()
	local redirects = uci:get_all("luci_splash_locations")
	--uci:load("luci_splash_locations")
	uci:revert("luci_splash_locations")
	-- For all redirects
	for k, v in pairs(redirects) do
		if v[".type"] == "redirect" then
			if v[".name"] ~= mac then
				-- Rewrite state
				uci:section("luci_splash_locations", "redirect", v[".name"], {
					location = v.location
				})
			end
		end
	end
	uci:save("luci_splash_redirects")
end
