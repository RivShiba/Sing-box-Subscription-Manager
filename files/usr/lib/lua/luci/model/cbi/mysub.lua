local m, s, urls, base, out, cron, log_level, btn, log, config_view

m = Map("mysub", translate("Sing-box Subscription Manager"), translate("Управление VLESS/VMess/Trojan/Hysteria2 подписками."))

-- ИСПОЛЬЗУЕМ NamedSection, так как конфиг имеет вид: config mysub 'main'
s = m:section(NamedSection, "main", "mysub", "")

-- Создаем вкладки (Tabs) для удобного интерфейса
s:tab("general", translate("Настройки / Settings"))
s:tab("logs", translate("Логи / Logs"))
s:tab("config", translate("Готовый конфиг / Result Config"))

-- ================= Вкладка General =================
urls = s:taboption("general", DynamicList, "urls", translate("Subscription URLs"), translate("Ссылки на подписки (v2rayN, Base64)."))

base = s:taboption("general", Value, "base_config", translate("Base Config File"), translate("Путь к базовому конфигу (в него добавятся прокси)."))
base.default = "/etc/mysub/template.json"

out = s:taboption("general", Value, "output_config", translate("Output Config File"), translate("Куда сохранить результат (Base + Подписки)."))
out.default = "/etc/mysub/mysub.json"

cron = s:taboption("general", Value, "cron", translate("Cron Interval"), translate("Стандартный формат cron, например '0 4 * * *'."))
cron.default = "0 4 * * *"

log_level = s:taboption("general", ListValue, "log_level", translate("Log Level"), translate("Уровень детализации логов."))
log_level:value("info", "Info")
log_level:value("debug", "Debug")
log_level.default = "info"

btn = s:taboption("general", Button, "_update", translate("Update Now"))
btn.inputtitle = translate("Run Update")
btn.inputstyle = "action"
btn.description = translate("Запустить скачивание и парсинг подписок прямо сейчас.")
btn.write = function(self, section)
    m.uci:commit("mysub")
    os.execute("/usr/libexec/mysub-update.sh > /dev/null 2>&1 &")
end

-- ================= Вкладка Logs =================
local get_log_url = luci.dispatcher.build_url("admin", "services", "mysub", "get_log")
log = s:taboption("logs", TextValue, "_log", translate("Parser Log"), translate("История выполнения скрипта. Логи обновляются автоматически каждые 2 секунды.") .. 
    [[<br/><br/><button class="btn cbi-button cbi-button-apply" type="button" onclick="
        var ta = document.getElementById('cbid.mysub.main._log');
        if (ta) {
            XHR.get(']] .. get_log_url .. [[', null,
                function(x) {
                    if (x && x.responseText) {
                        ta.value = x.responseText;
                        ta.scrollTop = ta.scrollHeight;
                    }
                }
            );
        }
    ">Refresh Logs</button>
    <script type="text/javascript">
        setInterval(function() {
            var ta = document.getElementById('cbid.mysub.main._log');
            if (ta && ta.offsetParent !== null) { // only if visible
                XHR.get(']] .. get_log_url .. [[', null,
                    function(x) {
                        if (x && x.responseText && ta.value !== x.responseText) {
                            var isBottom = (ta.scrollHeight - ta.offsetHeight) - ta.scrollTop < 20;
                            ta.value = x.responseText;
                            if (isBottom) {
                                ta.scrollTop = ta.scrollHeight;
                            }
                        }
                    }
                );
            }
        }, 2000);
    </script>]])
log.readonly = true
log.rows = 20
log.cfgvalue = function(self, section)
    return nixio.fs.readfile("/var/log/mysub.log") or "Логи пусты. Нажмите 'Run Update', чтобы запустить парсер."
end

-- ================= Вкладка Config =================
config_view = s:taboption("config", TextValue, "_config_view", translate("Generated Config (JSON)"), translate("Финальный результат после слияния базового конфига и скачанных серверов."))
config_view.readonly = true
config_view.rows = 30
config_view.cfgvalue = function(self, section)
    local out_path = m.uci:get("mysub", "main", "output_config") or "/etc/mysub/mysub.json"
    return nixio.fs.readfile(out_path) or "Конфиг еще не сгенерирован или файл не найден."
end

-- Хук для обновления crontab при сохранении настроек
function m.on_after_commit(self)
    local c = m.uci:get("mysub", "main", "cron")
    os.execute("sed -i '/mysub-update/d' /etc/crontabs/root 2>/dev/null")
    if c and c ~= "" then
        -- shellquote() prevents cron (a free-text UCI value) from being
        -- interpreted as shell syntax, e.g. "0 4 * * *'; rm -rf / #"
        local safe_line = luci.util.shellquote(c .. " /usr/libexec/mysub-update.sh")
        os.execute("echo " .. safe_line .. " >> /etc/crontabs/root")
    end
    os.execute("/etc/init.d/cron restart")
end

return m