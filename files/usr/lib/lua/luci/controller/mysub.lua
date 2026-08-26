module("luci.controller.mysub", package.seeall)

function index()
    entry({"admin", "services", "mysub"}, cbi("mysub"), _("Sing-box Subscriptions"), 60).dependent = false
    entry({"admin", "services", "mysub", "update"}, call("action_update"), nil).leaf = true
    entry({"admin", "services", "mysub", "get_log"}, call("action_get_log"), nil).leaf = true
end

function action_update()
    os.execute("/usr/libexec/mysub-update.sh > /dev/null 2>&1 &")
    luci.http.status(200, "OK")
    luci.http.prepare_content("text/plain")
    luci.http.write("Update triggered")
end

function action_get_log()
    local log = nixio.fs.readfile("/var/log/mysub.log") or ""
    luci.http.prepare_content("text/plain")
    luci.http.write(log)
end